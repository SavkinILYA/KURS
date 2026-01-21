### Курсовая работа на профессии "DevOps-инженер с нуля"

## Архитектура решения

Инфраструктура организована в виде VPC с разделением на публичные и приватные подсети. Весь внешний трафик проходит через Application Load Balancer.

```mermaid
graph TD
    subgraph Yandex_Cloud [Yandex Cloud VPC]
        style Yandex_Cloud fill:#f9f9f9,stroke:#333,stroke-width:2px

        User((Internet User)) --> ALB
        Admin((Admin)) --> Bastion

        subgraph Public_Zone [Public Subnet 192.168.10.0/24]
            style Public_Zone fill:#e1f5fe,stroke:#0277bd
            ALB[Application Load Balancer]
            Bastion[Bastion Host / NAT]
            Grafana[Grafana Dashboard]
            Kibana[Kibana Interface]
        end

        subgraph Private_Zone [Private Subnets]
            style Private_Zone fill:#e8f5e9,stroke:#2e7d32
            
            subgraph Zone_A [Zone A]
                WebA[Web Server A]
            end
            
            subgraph Zone_B [Zone B]
                WebB[Web Server B]
            end
            
            Prometheus[Prometheus Server]
            Elastic[Elasticsearch Node]
        end

        ALB --> WebA
        ALB --> WebB
        
        Bastion -.->|SSH/Provisioning| WebA
        Bastion -.->|SSH/Provisioning| WebB
        Bastion -.->|SSH/Provisioning| Prometheus
        Bastion -.->|SSH/Provisioning| Elastic

        %% Monitoring Flows
        Prometheus -.->|Pull Metrics :9100| WebA
        Prometheus -.->|Pull Metrics :9100| WebB
        Grafana -->|Query| Prometheus

        %% Logging Flows
        WebA -.->|Filebeat Push| Elastic
        WebB -.->|Filebeat Push| Elastic
        Kibana -->|Query| Elastic
    end
```

## Развертывание

1. Инфраструктура (Terraform)


```bash
cd terraform

# Инициализация
terraform init

# Применение конфигурации
terraform apply -auto-approve

# Сохранение outputs
terraform output > ../terraform-outputs.txt
```

2. Настройка серверов (Ansible)
   
```bash
cd ansible

# Обновление inventory из Terraform outputs
ansible-playbook generate_inventory.yml

# Настройка web-серверов
ansible-playbook -i inventories/hosts.yml playbooks/site.yml

# Настройка мониторинга
ansible-playbook -i inventories/hosts.yml playbooks/monitoring.yml

# Настройка логирования
ansible-playbook -i inventories/hosts.yml playbooks/logging.yml
```
## Доступ к сервисам

| Сервис | URL | Логин/Пароль | Описание |
| :--- | :--- | :--- | :--- |
| **Сайт** | [http://158.160.217.90](http://158.160.217.90) | - | Балансировка между web-a и web-b |
| **Grafana** | [http://178.154.200.203:3000](http://178.154.200.203:3000) | admin/admin | Визуализация метрик |
| **Kibana** | [http://89.169.130.108:5601](http://89.169.130.108:5601) | - | Анализ логов |
| **Prometheus** | [http://192.168.20.30:9090](http://192.168.20.30:9090) <br> *(через bastion)* | - | Сбор метрик |
