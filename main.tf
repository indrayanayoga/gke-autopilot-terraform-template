#Example Template for GKE Autopilot 

provider "google" {
    project = var.project_name  
    region = local.region
}

data "google_project" "project" {
  project_id = var.project_name   
}

locals {
    region = "asia-southeast2"
    apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
    "dns.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "gkebackup.googleapis.com",
    "artifactregistry.googleapis.com"]

}

#Enable necessary APIs: Compute Engine API & Kubernetes API
resource "google_project_service" "enabled-apis" {
    for_each = toset(local.apis)
    service = each.key
    disable_on_destroy = false
}
resource "google_compute_network" "gke-vpc" {
    name = "gke-vpc"
    auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke-subnet" {
    name = "nodes-subnet"
    ip_cidr_range = "XXXXXXXX"
    region = local.region
    network = google_compute_network.gke-vpc.id
    private_ip_google_access = true

    secondary_ip_range {
        range_name = "pods-subnet"
        ip_cidr_range = "YYYYYYYY"
    }

    secondary_ip_range {
        range_name = "services-subnet"
        ip_cidr_range = "ZZZZZZZZZ"
    }
}

resource "google_compute_address" "bastion_ip" {
  name = "reserved-bastion-ip"
  address_type = "INTERNAL"
  subnetwork = google_compute_subnetwork.gke-subnet.id                        
  purpose = "GCE_ENDPOINT"                    
}

resource "google_compute_router" "vpc-router" {
    name = "vpc-router"
    network = google_compute_network.gke-vpc.id
}

resource "google_compute_router_nat" "vpc-nat" {
    name = "vpc-nat"
    router = google_compute_router.vpc-router.name
    nat_ip_allocate_option = "AUTO_ONLY"
    source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
        subnetwork {
            name                    = google_compute_subnetwork.gke-subnet.id
            source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE"]
  }
}

resource "google_compute_disk" "bastion-disk" {
  name = "${var.cluster_name}-bastion-disk"
  image = "ubuntu-os-cloud/ubuntu-2204-lts"
  zone = "asia-southeast2-a"
  type = "pd-standard"
  size = "20"
  create_snapshot_before_destroy = true
}


resource "google_compute_instance" "bastion" {
  name = "${var.cluster_name}-bastion"
  zone = "asia-southeast2-a"
  machine_type = "e2-small"
  network_interface {
    subnetwork = google_compute_subnetwork.gke-subnet.id
    network_ip = google_compute_address.bastion_ip.address
  }
  boot_disk {
    source = google_compute_disk.bastion-disk.id
    auto_delete = false
  }
  metadata = {
    enable-oslogin = "TRUE"
  }
  tags = ["${var.cluster_name}-bastion"]
}

resource "google_compute_firewall" "default" {
  name    = "allow-ssh-from-google"
  network = google_compute_network.gke-vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
  target_tags = ["${var.cluster_name}-bastion"]
}


resource "google_container_cluster" "gke-cluster" {
    name     = "${var.cluster_name}"
    location = local.region
    enable_autopilot = true
    network    = google_compute_network.gke-vpc.id
    subnetwork = google_compute_subnetwork.gke-subnet.id

    private_cluster_config {
        enable_private_nodes    = true
        enable_private_endpoint = true
        master_ipv4_cidr_block = "172.16.4.0/28"
    }

    master_authorized_networks_config {
      cidr_blocks {
        cidr_block = google_compute_subnetwork.gke-subnet.ip_cidr_range
      }
    }
    
    deletion_protection = false

    release_channel {
        channel = "STABLE"
    }

    logging_config {
        enable_components = ["SYSTEM_COMPONENTS","WORKLOADS"]
   }

    monitoring_config {
       enable_components = [ "SYSTEM_COMPONENTS", "POD", "DEPLOYMENT", "STATEFULSET", "STORAGE" ]
       managed_prometheus {
           enabled = true
       }
    }

    maintenance_policy {
        recurring_window {
            start_time = "2025-01-01T18:00:00Z"
            end_time = "2025-01-01T22:00:00Z"
            recurrence = "FREQ=DAILY"
         }
    }
    
    ip_allocation_policy {
        cluster_secondary_range_name  = google_compute_subnetwork.gke-subnet.secondary_ip_range[0].range_name
        services_secondary_range_name = google_compute_subnetwork.gke-subnet.secondary_ip_range[1].range_name
    }
}

resource "google_gke_backup_backup_plan" "gke-backup" {
  name = "${var.cluster_name}-backup"
  project = "${var.project_name}"
  location = local.region
  cluster = google_container_cluster.gke-cluster.id
  retention_policy {
    backup_retain_days = 7
  }
  backup_config {
    all_namespaces = true 
    include_secrets = true
    include_volume_data = true
  }
  
  backup_schedule {
    cron_schedule =  "0 18 * * *"
  }
}

resource "google_project_iam_member" "compute_default" {
  project = var.project_name
  member = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  role = "roles/container.defaultNodeServiceAccount"
}
