#!/bin/sh
set -eu

# O que este script faz:
# 1. Checa as variáveis de ambiente para o banco de dados.
# 2. Entra em um loop que tenta se conectar ao banco de dados.
# 3. Só sai do loop quando o banco de dados está pronto para aceitar conexões.
# 4. Executa o comando de inicialização do banco de dados.
# 5. Inicia o servidor Gunicorn.


DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-}"
DB_NAME="${DB_NAME:-}"

fetch_db_from_secret() {
  python3 - <<'PY'
import os, sys, json
import boto3
from botocore.exceptions import BotoCoreError, ClientError

secret_name = os.getenv("SECRET_NAME", "prd/rds/togglemaster")
region = os.getenv("AWS_REGION", "sa-east-1")

try:
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_name)
except (BotoCoreError, ClientError) as exc:
    print(f"ERROR_SECRET={exc}")
    sys.exit(1)

if "SecretString" in response:
    secret = json.loads(response["SecretString"])
elif "SecretBinary" in response:
    secret = json.loads(response["SecretBinary"].decode("utf-8"))
else:
    print("ERROR_SECRET=Secret Manager retornou formato inválido")
    sys.exit(1)

host = secret.get("host") or secret.get("hostname") or ""
port = secret.get("port") or secret.get("PORT") or ""
name = (
    secret.get("dbname")
    or secret.get("database")
    or secret.get("DB_NAME")
    or secret.get("dbInstanceIdentifier")
    or ""
)
print(host)
print(port)
print(name)
PY
}

# Verifique se as variáveis de ambiente do banco de dados estão definidas,
# ou se o Secrets Manager está habilitado.
if [ "${USE_SECRETS_MANAGER:-true}" = "true" ] || [ "${USE_SECRETS_MANAGER:-true}" = "1" ]; then
  if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ]; then
    secret_values=$(fetch_db_from_secret)
    if echo "$secret_values" | grep -q '^ERROR_SECRET='; then
      echo "$secret_values" | sed 's/^ERROR_SECRET=//'
      exit 1
    fi
    DB_HOST=$(echo "$secret_values" | sed -n '1p')
    DB_PORT=$(echo "$secret_values" | sed -n '2p')
    if [ -z "$DB_NAME" ]; then
      DB_NAME=$(echo "$secret_values" | sed -n '3p')
    fi
  fi
  if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ]; then
    echo "Erro: DB_HOST e DB_PORT não foram encontrados, mesmo usando Secrets Manager."
    exit 1
  fi
  echo "Usando AWS Secrets Manager para obter as credenciais do banco de dados."
  echo "Aguardando o banco de dados em ${DB_HOST}:${DB_PORT}..."
else
  if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_NAME" ]; then
    echo "Erro: As variáveis de ambiente do banco de dados (DB_HOST, DB_PORT, DB_NAME) devem ser definidas quando não estiver usando Secrets Manager."
    exit 1
  fi
  echo "Aguardando o banco de dados em ${DB_HOST}:${DB_PORT}..."
fi

# Loop para aguardar o banco de dados ficar disponível
# Para PostgreSQL, usamos o `pg_isready` (instale postgresql-client na imagem)
# Usamos `until` em vez de `while ! ...` para maior portabilidade entre /bin/sh implementations
until pg_isready -h "$DB_HOST" -p "$DB_PORT" -q -U "${DB_USER:-}" >/dev/null 2>&1; do
  echo "Banco de dados indisponível - aguardando..."
  sleep 1
done

echo "Banco de dados disponível!"

# Executa o comando de inicialização/migração do banco de dados (se existir)
if command -v flask >/dev/null 2>&1; then
  echo "Executando a inicialização do banco de dados..."
  flask init-db || true
fi

# Verificação final: valida as credenciais tentando conexão real via app.check_db_connection()
echo "Validando credenciais do banco de dados..."
python3 - <<'PY'
from app import check_db_connection
import sys
try:
    check_db_connection()
except Exception as e:
    print(f"Falha na checagem do banco de dados: {e}")
    sys.exit(1)
print("Conexão com o banco de dados validada com sucesso.")
PY

# Inicia a aplicação principal (Gunicorn)
echo "Iniciando o servidor Gunicorn..."
exec gunicorn --bind 0.0.0.0:5000 app:app
