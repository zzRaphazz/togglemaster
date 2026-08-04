import os
import json
import boto3
from flask import Flask, request, jsonify
import psycopg2
from psycopg2.extras import RealDictCursor
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

def get_db_secret():
    # Require secret name and region from environment (no sensible defaults here)
    SECRET_NAME = os.getenv("SECRET_NAME")
    REGION_NAME = os.getenv("AWS_REGION")

    if not SECRET_NAME or not REGION_NAME:
        raise RuntimeError(
            "Missing SECRET_NAME or AWS_REGION environment variables.\n"
            "Set them in your local .env (gitignored) or in the environment before starting the app.\n"
            "Example .env entries:\n"
            "SECRET_NAME=env/rds/secrets\n"
            "AWS_REGION=virginia-1\n"
        )

    client = boto3.client("secretsmanager", region_name=REGION_NAME)
    response = client.get_secret_value(SecretId=SECRET_NAME)

    if "SecretString" in response:
        return json.loads(response["SecretString"])
    if "SecretBinary" in response:
        return json.loads(response["SecretBinary"].decode("utf-8"))

    raise RuntimeError("Secret Manager retornou um valor inesperado sem SecretString ou SecretBinary")


def get_db_config():
    use_secrets = os.getenv("USE_SECRETS_MANAGER", "true").lower() in ("1", "true", "yes")
    secret = {}

    if use_secrets:
        try:
            secret = get_db_secret()
        except Exception as e:
            print(f"Aviso: não foi possível carregar secret do Secrets Manager: {e}")
            print("Tentando usar variáveis de ambiente em vez do Secrets Manager...")
            secret = {}

    db_config = {
        "host": secret.get("host") or secret.get("hostname") or os.getenv("DB_HOST"),
        "port": secret.get("port") or secret.get("PORT") or os.getenv("DB_PORT") or 5432,
        "database": (
            secret.get("dbname")
            or secret.get("database")
            or os.getenv("DB_NAME")
            or secret.get("dbInstanceIdentifier")
        ),
        "user": secret.get("username") or secret.get("user") or os.getenv("DB_USER"),
        "password": secret.get("password") or os.getenv("DB_PASSWORD"),
    }

    # Avisos sobre a origem do nome do banco
    if secret and secret.get("dbInstanceIdentifier") and db_config["database"] == secret.get("dbInstanceIdentifier") and not (secret.get("dbname") or secret.get("database")):
        print("Aviso: usando 'dbInstanceIdentifier' do secret como nome do banco. Verifique se esse é o nome correto do banco dentro do PostgreSQL.")
    # Se não houver nome do banco no secret ou em DB_NAME, a configuração ficará incompleta
    # e `get_db_connection` levantará um erro. Evitamos assumir um fallback implícito.

    source = "Secrets Manager" if secret else "variáveis de ambiente"
    print(f"Usando configuração de banco de dados a partir de: {source}")
    return db_config


def get_db_connection():
    db_config = get_db_config()
    missing = [key for key, value in db_config.items() if not value]
    if missing:
        raise RuntimeError(
            "Configuração de banco de dados incompleta. Verifique Secrets Manager ou variáveis de ambiente: "
            + ", ".join(missing)
        )

    port = int(db_config["port"]) if db_config["port"] else None
    return psycopg2.connect(
        host=db_config["host"],
        port=port,
        database=db_config["database"],
        user=db_config["user"],
        password=db_config["password"],
    )

def check_db_connection():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.fetchone()
        cur.close()
        conn.close()
        print("Conexão com o banco de dados: OK")
    except Exception as e:
        raise RuntimeError(f"Falha ao conectar no banco de dados: {e}")


def init_db():
    print("Tentando inicializar a tabela 'flags'...")
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS flags (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100) UNIQUE NOT NULL,
                is_enabled BOOLEAN NOT NULL DEFAULT false,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.commit()
        cur.close()
        conn.close()
        print("Tabela 'flags' inicializada com sucesso.")
    except psycopg2.OperationalError as e:
        print(f"Erro de conexão ao inicializar o banco de dados: {e}")
    except Exception as e:
        print(f"Um erro inesperado ocorreu durante a inicialização do DB: {e}")

@app.cli.command("init-db")
def init_db_command():
    init_db()

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({"status": "ok"}), 200

@app.route('/flags', methods=['POST'])
def create_flag():
    data = request.get_json()
    if not data or 'name' not in data:
        return jsonify({"error": "O campo 'name' é obrigatório"}), 400
    
    name = data['name']
    is_enabled = data.get('is_enabled', False)
    
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("INSERT INTO flags (name, is_enabled) VALUES (%s, %s)", (name, is_enabled))
        conn.commit()
    except psycopg2.IntegrityError:
        return jsonify({"error": f"A flag '{name}' já existe"}), 409
    except Exception as e:
        return jsonify({"error": "Erro interno no servidor ao criar a flag", "details": str(e)}), 500
    finally:
        if 'cur' in locals() and not cur.closed:
            cur.close()
        if 'conn' in locals() and not conn.closed:
            conn.close()
            
    return jsonify({"message": f"Flag '{name}' criada com sucesso"}), 201

@app.route('/flags', methods=['GET'])
def get_flags():
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT name, is_enabled FROM flags ORDER BY name")
        flags = cur.fetchall()
    except Exception as e:
        return jsonify({"error": "Erro interno no servidor ao buscar as flags", "details": str(e)}), 500
    finally:
        if 'cur' in locals() and not cur.closed:
            cur.close()
        if 'conn' in locals() and not conn.closed:
            conn.close()

    return jsonify(flags), 200

@app.route('/flags/<string:name>', methods=['GET'])
def get_flag_status(name):
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT name, is_enabled FROM flags WHERE name = %s", (name,))
        flag = cur.fetchone()
    except Exception as e:
        return jsonify({"error": "Erro interno no servidor ao buscar a flag", "details": str(e)}), 500
    finally:
        if 'cur' in locals() and not cur.closed:
            cur.close()
        if 'conn' in locals() and not conn.closed:
            conn.close()
    
    if flag:
        return jsonify(flag), 200
    return jsonify({"error": "Flag não encontrada"}), 404

@app.route('/flags/<string:name>', methods=['PUT'])
def update_flag(name):
    data = request.get_json()
    if data is None or 'is_enabled' not in data or not isinstance(data['is_enabled'], bool):
        return jsonify({"error": "O campo 'is_enabled' (booleano) é obrigatório"}), 400
        
    is_enabled = data['is_enabled']
    
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("UPDATE flags SET is_enabled = %s WHERE name = %s", (is_enabled, name))
        
        if cur.rowcount == 0:
            return jsonify({"error": "Flag não encontrada"}), 404
            
        conn.commit()
    except Exception as e:
        return jsonify({"error": "Erro interno no servidor ao atualizar a flag", "details": str(e)}), 500
    finally:
        if 'cur' in locals() and not cur.closed:
            cur.close()
        if 'conn' in locals() and not conn.closed:
            conn.close()
    
    return jsonify({"message": f"Flag '{name}' atualizada"}), 200

if __name__ == '__main__':
    check_db_connection()
    app.run(host='0.0.0.0', port=5000)
