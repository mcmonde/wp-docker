# 🚀 WordPress Docker Auto-Scaling Stack

This project is a **Docker-based WordPress stack** with:

- Auto-generated environment configuration
- Dynamic resource allocation (CPU + RAM aware)
- MariaDB tuning
- PHP-FPM optimization
- Redis caching
- Nginx reverse proxy
- Persistent WordPress content

---

# 📦 Requirements

- Docker
- Docker Compose
- Linux server (recommended)
- At least 2GB RAM (4GB+ recommended)

---

# ⚙️ Project Setup Flow

## 1. Generate environment configuration

Run the auto-generator script:

```bash
./generate-env.sh
```
this will generate 3 files:
- .env (main configuration)
- mysql/my.cnf (MariaDB optimized config)
- php/custom.ini (PHP optimized config)

## 2. Modify the .env file espcially the ff:

```
PUID=1000
PGID=1000

PROJECT_NAME=wordpress

DOMAIN=http://localhost
EMAIL=your_email@here.com
DB_PREFIX=wp_

# Database Secrets
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=wordpress
MYSQL_USER=default
MYSQL_PASSWORD=secret
```
```bash
nano .env
```
## 3. Start Docker environment
```bash
docker compose up -d
```