# =============================================================================
# TERRAFORM & PROVIDER CONFIGURATION
# =============================================================================

terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.135.0"
    }
  }
}

# Provider authentication via service account key
provider "yandex" {
  service_account_key_file = "./authorized_key.json"
  cloud_id                 = "b1gjhqujrn3rkkkbln0o"
  folder_id                = "b1ggof4ggrcm8f78sus5"
  zone                     = "ru-central1-a"
}

# Base OS image for all instances
data "yandex_compute_image" "ubuntu_2204" {
  family = "ubuntu-2204-lts"
}

# =============================================================================
# NETWORKING: VPC & SUBNETS
# =============================================================================

# Main VPC network
resource "yandex_vpc_network" "vpc" {
  name = "diploma-vpc"
}

# Public subnet for bastion, Grafana, Kibana and ALB
resource "yandex_vpc_subnet" "public_a" {
  name           = "public-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.vpc.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

# Private subnet A (monitoring, logging, web-a)
resource "yandex_vpc_subnet" "private_a" {
  name           = "private-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.vpc.id
  v4_cidr_blocks = ["192.168.20.0/24"]
  route_table_id = yandex_vpc_route_table.private_rt.id
}

# Private subnet B (web-b)
resource "yandex_vpc_subnet" "private_b" {
  name           = "private-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.vpc.id
  v4_cidr_blocks = ["192.168.30.0/24"]
  route_table_id = yandex_vpc_route_table.private_rt.id
}

# =============================================================================
# SECURITY GROUPS
# =============================================================================

# Public SG - open access for Grafana, Kibana, SSH
resource "yandex_vpc_security_group" "sg_public" {
  name       = "sg-public"
  network_id = yandex_vpc_network.vpc.id

  ingress {
    description    = "SSH from anywhere"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description    = "Grafana UI"
    protocol       = "TCP"
    port           = 3000
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description    = "Kibana UI"
    protocol       = "TCP"
    port           = 5601
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Node Exporter metrics"
    protocol       = "TCP"
    port           = 9100
    v4_cidr_blocks = ["192.168.20.0/24", "192.168.10.0/24"]
  }

  ingress {
    description    = "Nginx Log Exporter metrics"
    protocol       = "TCP"
    port           = 4040
    v4_cidr_blocks = ["192.168.20.0/24", "192.168.10.0/24"]
  }

  egress {
    description    = "All outbound traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Private SG - internal traffic only
resource "yandex_vpc_security_group" "sg_private" {
  name       = "sg-private"
  network_id = yandex_vpc_network.vpc.id

  ingress {
    description    = "Internal network access"
    protocol       = "ANY"
    v4_cidr_blocks = ["192.168.0.0/16"]
  }

  egress {
    description    = "All outbound traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# =============================================================================
# APPLICATION LOAD BALANCER
# =============================================================================

resource "yandex_alb_load_balancer" "web_alb" {
  name       = "web-alb"
  network_id = yandex_vpc_network.vpc.id

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.public_a.id
    }
  }

  listener {
    name = "web-listener"
    endpoint {
      ports = [80]
      address {
        external_ipv4_address {}
      }
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.web_router.id
      }
    }
  }
}

resource "yandex_alb_http_router" "web_router" {
  name = "web-router"
}

resource "yandex_alb_virtual_host" "web_vh" {
  name           = "web-vh"
  http_router_id = yandex_alb_http_router.web_router.id
  authority      = ["*"]

  route {
    name = "web-route"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.web_bg.id
      }
    }
  }
}

resource "yandex_alb_backend_group" "web_bg" {
  name = "web-bg"

  http_backend {
    name             = "web-backend"
    port             = 80
    target_group_ids = [yandex_alb_target_group.web_tg.id]

    healthcheck {
      timeout  = "10s"
      interval = "2s"
      http_healthcheck {
        path = "/"
      }
    }
  }
}

resource "yandex_alb_target_group" "web_tg" {
  name = "web-tg"

  target {
    subnet_id  = yandex_vpc_subnet.private_a.id
    ip_address = yandex_compute_instance.web_a.network_interface[0].ip_address
  }

  target {
    subnet_id  = yandex_vpc_subnet.private_b.id
    ip_address = yandex_compute_instance.web_b.network_interface[0].ip_address
  }
}

# =============================================================================
# NAT INSTANCE (Private network internet access)
# =============================================================================

resource "yandex_compute_instance" "nat" {
  name        = "nat-instance"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 10
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public_a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.sg_public.id]
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_a.id
    security_group_ids = [yandex_vpc_security_group.sg_private.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
    user-data = <<-EOF
      #cloud-config
      bootcmd:
        - sysctl -w net.ipv4.ip_forward=1
      runcmd:
        - iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        - iptables -A FORWARD -i eth1 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        - iptables -A FORWARD -i eth0 -o eth1 -j ACCEPT
        - apt-get update -y && apt-get install -y iptables-persistent
        - systemctl enable netfilter-persistent
      write_files:
        - path: /etc/sysctl.d/99-ip-forward.conf
          content: "net.ipv4.ip_forward = 1\n"
          permissions: '0644'
    EOF
  }
}

# =============================================================================
# BASTION HOST (Jump server)
# =============================================================================

resource "yandex_compute_instance" "bastion" {
  name        = "bastion"
  platform_id = "standard-v3"
  
  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 10
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public_a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.sg_public.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true  # Экономия 70%
  }
}

# =============================================================================
# ECOMPUTE INSTANCES: Web servers (2 zones)
# =============================================================================

resource "yandex_compute_instance" "web_a" {
  name        = "web-a"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 10
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_a.id
    security_group_ids = [yandex_vpc_security_group.sg_private.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

resource "yandex_compute_instance" "web_b" {
  name        = "web-b"
  zone        = "ru-central1-b"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 10
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_b.id
    security_group_ids = [yandex_vpc_security_group.sg_private.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

# =============================================================================
# MONITORING STACK
# =============================================================================

resource "yandex_compute_instance" "prometheus" {
  name        = "prometheus"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 20
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_a.id
    security_group_ids = [yandex_vpc_security_group.sg_private.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

resource "yandex_compute_instance" "grafana" {
  name        = "grafana"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 20
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public_a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.sg_public.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

# =============================================================================
# LOGGING STACK
# =============================================================================

resource "yandex_compute_instance" "elasticsearch" {
  name        = "elasticsearch"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 8
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 30
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_a.id
    security_group_ids = [yandex_vpc_security_group.sg_private.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

resource "yandex_compute_instance" "kibana" {
  name        = "kibana"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 20
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public_a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.sg_public.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

# =============================================================================
# ROUTING & NETWORKING
# =============================================================================

resource "yandex_vpc_route_table" "private_rt" {
  network_id = yandex_vpc_network.vpc.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    next_hop_address   = yandex_compute_instance.nat.network_interface[1].ip_address
  }
}

# =============================================================================
# BACKUP SCHEDULE (Daily snapshots, 7 days retention)
# =============================================================================

resource "yandex_compute_snapshot_schedule" "daily_backup" {
  name        = "daily-vm-backup"
  description = "Ежедневные бэкапы ВМ с хранением 7 дней"

  schedule_policy {
    expression = "0 3 * * *"  # 3:00 AM UTC
  }
  
  retention_period = "168h"  # 7 days

  disk_ids = [
    yandex_compute_instance.web_a.boot_disk[0].disk_id,
    yandex_compute_instance.web_b.boot_disk[0].disk_id,
    yandex_compute_instance.prometheus.boot_disk[0].disk_id,
    yandex_compute_instance.elasticsearch.boot_disk[0].disk_id,
    yandex_compute_instance.grafana.boot_disk[0].disk_id,
    yandex_compute_instance.kibana.boot_disk[0].disk_id,
    yandex_compute_instance.bastion.boot_disk[0].disk_id,
    yandex_compute_instance.nat.boot_disk[0].disk_id,
  ]
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "alb_public_ip" {
  description = "Публичный IP балансировщика для доступа к сайту"
  value       = yandex_alb_load_balancer.web_alb.listener[0].endpoint[0].address[0].external_ipv4_address[0].address
}

output "bastion_public_ip" {
  description = "Bastion host IP для SSH доступа"
  value       = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
}

output "grafana_public_ip" {
  description = "Grafana: http://<IP>:3000 (admin/admin)"
  value       = yandex_compute_instance.grafana.network_interface[0].nat_ip_address
}

output "kibana_public_ip" {
  description = "Kibana: http://<IP>:5601"
  value       = yandex_compute_instance.kibana.network_interface[0].nat_ip_address
}

output "ssh_access_commands" {
  description = "Команды для SSH доступа через bastion"
  value       = <<EOT

Доступ ко всем серверам через bastion:
ssh -J ubuntu@${yandex_compute_instance.bastion.network_interface[0].nat_ip_address} ubuntu@<IP_сервера>
EOT
}
