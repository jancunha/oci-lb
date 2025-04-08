// Copyright (c) 2017, 2021, Oracle and/or its affiliates. All rights reserved.
// Licensed under the Mozilla Public License v2.0


variable "compartment_ocid" {}
variable "region" {}
variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key" {}
variable "ssh_public_key" {}

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "6.11.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  private_key_path  = var.private_key
  region       = var.region
}

variable "ad_region_mapping" {
  type = map(string)

  default = {
    us-phoenix-1  = 2
    us-ashburn-1  = 2
    sa-saopaulo-1 = 1
  }
}

variable "images" {
  type = map(string)

  default = {
    # See https://docs.us-phoenix-1.oraclecloud.com/images/
    # Oracle-provided image "Oracle-Linux-7.9-2020.10.26-0"
    us-phoenix-1  = "ocid1.image.oc1.phx.aaaaaaaacirjuulpw2vbdiogz3jtcw3cdd3u5iuangemxq5f5ajfox3aplxa"
    us-ashburn-1  = "ocid1.image.oc1.iad.aaaaaaaabbg2rypwy5pwnzinrutzjbrs3r35vqzwhfjui7yibmydzl7qgn6a"
    sa-saopaulo-1 = "ocid1.image.oc1.sa-saopaulo-1.aaaaaaaaudio63gdicxwujhfok7jdyewf6iwl6sgcaqlyk4fvttg3bw6gbpq"
  }
}

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = var.ad_region_mapping[var.region]
}

resource "oci_core_virtual_network" "tcb_vcn" {
  cidr_block     = "10.1.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "tcbVCN"
  dns_label      = "tcbvcn"
}

resource "oci_core_subnet" "tcb_subnet" {
  cidr_block        = "10.1.20.0/24"
  display_name      = "tcbSubnet"
  dns_label         = "tcbsubnet"
  security_list_ids = [oci_core_security_list.tcb_security_list.id]
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_virtual_network.tcb_vcn.id
  route_table_id    = oci_core_route_table.tcb_route_table.id
  dhcp_options_id   = oci_core_virtual_network.tcb_vcn.default_dhcp_options_id
}

resource "oci_core_internet_gateway" "tcb_internet_gateway" {
  compartment_id = var.compartment_ocid
  display_name   = "tcbIG"
  vcn_id         = oci_core_virtual_network.tcb_vcn.id
}

resource "oci_core_route_table" "tcb_route_table" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.tcb_vcn.id
  display_name   = "tcbRouteTable"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.tcb_internet_gateway.id
  }
}

resource "oci_core_security_list" "tcb_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.tcb_vcn.id
  display_name   = "tcbSecurityList"

  egress_security_rules {
    protocol    = "6"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "22"
      min = "22"
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      max = "80"
      min = "80"
    }
  }
}

resource "oci_core_instance" "webserver1" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "webserver1"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.tcb_subnet.id
    display_name     = "primaryvnic"
    assign_public_ip = true
    hostname_label   = "webserver1"
  }

  source_details {
    source_type = "image"
    source_id   = var.images[var.region]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

resource "oci_core_instance" "webserver2" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "webserver2"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.tcb_subnet.id
    display_name     = "primaryvnic"
    assign_public_ip = true
    hostname_label   = "webserver2"
  }

  source_details {
    source_type = "image"
    source_id   = var.images[var.region]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

# reservar ip público
resource "oci_core_public_ip" "tcb_reserved_ip" {
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"

  lifecycle {
    ignore_changes = [private_ip_id]
  }
}

/* Load Balancer */
# Adicionar detalhes
resource "oci_load_balancer" "tcb-lb" {
  shape          = "10Mbps"
  compartment_id = var.compartment_ocid

  subnet_ids = [
    oci_core_subnet.tcb_subnet.id,

  ]

  display_name = "tcb-lb"
  reserved_ips {
    id = oci_core_public_ip.tcb_reserved_ip.id
  }
}

# Escolha o BackendSet
resource "oci_load_balancer_backend_set" "tcb-lb-backset" {
  name             = "tcb-lb-backset"
  load_balancer_id = oci_load_balancer.tcb-lb.id
  policy           = "ROUND_ROBIN"

  health_checker {
    port                = "80"
    protocol            = "TCP"
    response_body_regex = ".*"
    url_path            = "/"
  }
}
# Criar backend 1
resource "oci_load_balancer_backend" "tcb-lb-backend1" {
  load_balancer_id = oci_load_balancer.tcb-lb.id
  backendset_name  = oci_load_balancer_backend_set.tcb-lb-backset.name
  ip_address       = oci_core_instance.webserver1.private_ip
  port             = 80
  backup           = false
  drain            = false
  offline          = false
  weight           = 1
}
# Criar backend 2
resource "oci_load_balancer_backend" "tcb-lb-backend2" {
  load_balancer_id = oci_load_balancer.tcb-lb.id
  backendset_name  = oci_load_balancer_backend_set.tcb-lb-backset.name
  ip_address       = oci_core_instance.webserver2.private_ip
  port             = 80
  backup           = false
  drain            = false
  offline          = false
  weight           = 1
}
#Configurar o Listner
resource "oci_load_balancer_listener" "tcb-lb-listener" {
  load_balancer_id         = oci_load_balancer.tcb-lb.id
  name                     = "tcb-lb-listener"
  default_backend_set_name = oci_load_balancer_backend_set.tcb-lb-backset.name
  port                     = 80
  protocol                 = "HTTP"


  connection_configuration {
    idle_timeout_in_seconds = "2"
  }
}

# Mostrar o IP Publico
output "lb_public_ip" {
  value = [oci_load_balancer.tcb-lb.ip_address_details]
}