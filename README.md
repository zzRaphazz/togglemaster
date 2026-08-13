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

## Diagramas de Arquitetura

- Diagrama da aplicação (componentes e fluxo): [architecture.mmd](architecture.mmd)
- Diagrama da arquitetura AWS (espaço reservado / placeholder): [aws-architecture.mmd](aws-architecture.mmd)

Os arquivos acima estão em formato Mermaid (`.mmd`). Você pode abri-los diretamente em ferramentas que suportem Mermaid ou converter para SVG/PNG para inclusão em apresentações.
