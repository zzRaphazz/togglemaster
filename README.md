# Tech Challenge - Fase 1: Plataforma "ToggleMaster"

Repository: https://github.com/zzRaphazz/togglemaster.git

Bem-vindo à primeira fase do Tech Challenge do curso de DevOps! Neste projeto, construiremos uma plataforma de *Feature Flag as a Service* chamada **ToggleMaster**.

## 📖 Cenário

A **DevOps Solutions Inc.** precisa de uma forma para que seus times de desenvolvimento possam lançar novas funcionalidades de forma segura e controlada. A solução é o **ToggleMaster**, uma plataforma interna que permitirá ativar ou desativar features em produção sem a necessidade de um novo deploy.

Nesta fase, entregamos um API monolítica simples para gerenciar *feature flags* que deve rodar diretamente em uma instância EC2 (sem Docker).

## 🎯 Objetivos da Fase 1

O objetivo principal é aplicar os conceitos fundamentais de DevOps e Cloud. Ao final desta fase, você deverá ser capaz de:

- Analisar uma aplicação monolítica e discutir suas vantagens e desvantagens.
- Desenhar uma arquitetura de nuvem inicial para uma aplicação web na AWS.
- Provisionar manualmente recursos essenciais na AWS (VPC, EC2, RDS, Security Groups).
- Realizar o deploy de uma aplicação, configurando a conexão com um banco de dados externo.
- Compreender e aplicar práticas básicas de segurança na AWS (IAM, Security Groups).

## 🛠️ Pré-requisitos

- Acesso a uma instância EC2 (Ubuntu 20.04/22.04) com SSH.
- Um banco PostgreSQL acessível (RDS ou similar).
- Python 3.8+ no EC2.
- Permissões/role com `secretsmanager:GetSecretValue` caso utilize AWS Secrets Manager.

---

## ⚙️ Guia de Instalação e Deploy na EC2

Este guia foca em executar o monolito diretamente na EC2 (sem Docker). Abaixo seguem os passos para **Ubuntu Server 20.04 / 22.04 LTS**.

### Opção B: Para Ubuntu Server 20.04 / 22.04 LTS

1. Atualize o sistema e instale ferramentas básicas:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git python3-pip python3-venv
```

2. Clone o repositório e entre na pasta do projeto:

```bash
git clone https://github.com/zzRaphazz/togglemaster.git
cd togglemaster
```

3. Crie e ative um ambiente virtual Python:

```bash
python3 -m venv venv
source venv/bin/activate
```

4. Instale as dependências:

```bash
pip install -r requirements.txt
```

5. Configure variáveis de ambiente (exemplo):

```bash
# opcional: usar Secrets Manager e role IAM
export SECRET_NAME=nome/rds/secrets
export AWS_REGION=xx-xxxx-1
export USE_SECRETS_MANAGER=true

# se não usar Secrets Manager, defina as variáveis DB_*
export DB_HOST='<endpoint-do-seu-rds>'
export DB_NAME='postgres'
export DB_USER='postgres'
export DB_PASSWORD='<senha-do-banco>'
```

6. Execute a aplicação (modo simples para avaliação):

```bash
# com venv ativado
python3 app.py
```

7. Verifique o endpoint de saúde:

```bash
curl http://<ip-publico-da-ec2>:5000/health
```

> Observação: Para um ambiente de produção, utilize um WSGI (por exemplo `gunicorn`) e um gerenciador de processo (`systemd`). Aqui mantemos a execução direta com `python3 app.py` conforme solicitado.

---

## 🔐 Segurança e boas práticas

- Nunca comite arquivos com segredos (arquivo `.env` deve estar em `.gitignore`).
- Se uma credencial foi exposta no repositório, rotacione-a imediatamente.
- Prefira AWS Secrets Manager + IAM Role em produção.
- Configure Security Groups: EC2 deve permitir entrada na porta `5000`; RDS deve aceitar conexões apenas do Security Group da EC2.

---

Se quiser, eu posso também:
- Gerar um `ENV_EXAMPLE` mais detalhado;
- Adicionar instruções para criar um `systemd` service para rodar o app com `gunicorn`.

---


## Automação de incialização com User Data da EC2

# ToggleMaster - Inicialização Automática na EC2 com SystemD

## Objetivo

Automatizar a inicialização da aplicação ToggleMaster após qualquer reinicialização da instância EC2, eliminando a necessidade de acesso manual via SSH para executar a aplicação.

Antes da automação, sempre que a instância era reiniciada era necessário:

```bash
cd /home/ec2-user/togglemaster
source venv/bin/activate
python app.py
```

Após a configuração, a aplicação é iniciada automaticamente durante o boot da EC2.

---

# Arquitetura

```text
Internet
    │
    ▼
EC2 Amazon Linux
    │
    ▼
SystemD
    │
    ▼
Flask Application
    │
    ▼
PostgreSQL RDS
```

---

# Estrutura do Projeto

```text
/home/ec2-user/togglemaster
│
├── app.py
├── .env
├── requirements.txt
└── venv/
```

Onde:

| Arquivo | Descrição |
|----------|------------|
| app.py | Aplicação Flask |
| .env | Credenciais do banco PostgreSQL |
| venv | Ambiente virtual Python |
| requirements.txt | Dependências do projeto |

---

# Solução Implementada

A solução utiliza:

- AWS EC2 User Data
- Linux SystemD
- Ambiente Virtual Python (venv)

O User Data cria automaticamente um serviço SystemD responsável por iniciar a aplicação no boot da instância. 
Isso permite que caso ocorra uma instabilidade na EC2, caso ocorra um shutdown a aplicação é reiniciada assim que EC2 estiver online novamente

---

# User Data Utilizado

```yaml
#cloud-config

runcmd:
  - |
      # Cria diretório para armazenamento dos logs da aplicação
      mkdir -p /var/log/togglemaster

      # Cria o serviço SystemD responsável pela aplicação
      cat > /etc/systemd/system/togglemaster.service << 'EOF'
      [Unit]
      Description=ToggleMaster Flask Application

      # Aguarda a inicialização da rede antes de subir a aplicação
      After=network.target

      [Service]

      # Executa o processo utilizando o usuário padrão da EC2
      User=ec2-user
      Group=ec2-user

      # Define o diretório de trabalho da aplicação
      WorkingDirectory=/home/ec2-user/togglemaster

      # Carrega automaticamente as variáveis do arquivo .env
      EnvironmentFile=/home/ec2-user/togglemaster/.env

      # Utiliza os binários instalados no ambiente virtual
      Environment="PATH=/home/ec2-user/togglemaster/venv/bin"

      # Comando responsável por iniciar a aplicação Flask
      ExecStart=/home/ec2-user/togglemaster/venv/bin/gunicorn \
          --workers 2 \
          --bind 0.0.0.0:5000 \
          app:app

      # Reinicia automaticamente o processo caso ele falhe
      Restart=always

      # Aguarda 5 segundos antes de tentar reiniciar
      RestartSec=5

      # Direciona saída padrão para arquivo de log
      StandardOutput=append:/var/log/togglemaster/app.log

      # Direciona erros para o mesmo arquivo de log
      StandardError=append:/var/log/togglemaster/app.log

      [Install]

      # Habilita o serviço para iniciar no boot da EC2
      WantedBy=multi-user.target
      EOF

      # Recarrega as definições dos serviços do SystemD
      systemctl daemon-reload

      # Habilita a execução automática no boot
      systemctl enable togglemaster

      # Inicia o serviço imediatamente
      systemctl restart togglemaster

final_message: "ToggleMaster configurado com sucesso"
```

---

# Explicação dos Comandos

## Criar diretório de logs

```bash
mkdir -p /var/log/togglemaster
```

Cria o diretório que armazenará os logs da aplicação.

A opção `-p` evita erro caso o diretório já exista.

---

## Criar o serviço SystemD

```bash
cat > /etc/systemd/system/togglemaster.service
```

Cria o arquivo de configuração do serviço responsável por iniciar a aplicação automaticamente.

---

## Definir dependência da rede

```ini
After=network.target
```

Garante que a aplicação só seja iniciada após a rede estar disponível.

Importante para aplicações que dependem de:

- PostgreSQL RDS
- APIs externas
- Serviços de autenticação

---

## Definir usuário de execução

```ini
User=ec2-user
Group=ec2-user
```

Executa a aplicação sem privilégios administrativos.

Boa prática de segurança.

---

## Definir diretório da aplicação

```ini
WorkingDirectory=/home/ec2-user/togglemaster
```

Equivale a executar:

```bash
cd /home/ec2-user/togglemaster
```

antes da inicialização.

---

## Carregar variáveis de ambiente

```ini
EnvironmentFile=/home/ec2-user/togglemaster/.env
```

Permite que o Flask acesse automaticamente:

```env
DB_HOST=
DB_PORT=
DB_NAME=
DB_USER=
DB_PASSWORD=
```

sem que essas informações fiquem expostas no código.

---

## Utilizar o ambiente virtual

```ini
Environment="PATH=/home/ec2-user/togglemaster/venv/bin"
```

Garante que o Python e todas as bibliotecas utilizadas sejam as versões instaladas dentro do projeto.

---

## Iniciar a aplicação

```ini
ExecStart=/home/ec2-user/togglemaster/venv/bin/python \
          /home/ec2-user/togglemaster/app.py
```

Equivale aos comandos manuais:

```bash
cd /home/ec2-user/togglemaster

source venv/bin/activate

python app.py
```

---

## Reinício automático em caso de falha

```ini
Restart=always
```

Caso a aplicação seja encerrada inesperadamente, o SystemD tenta reiniciá-la automaticamente.

---

## Intervalo entre tentativas

```ini
RestartSec=5
```

Define uma espera de 5 segundos antes de cada tentativa de reinício.

---

## Log da aplicação

```ini
StandardOutput=append:/var/log/togglemaster/app.log
```

Armazena mensagens normais da aplicação.

```ini
StandardError=append:/var/log/togglemaster/app.log
