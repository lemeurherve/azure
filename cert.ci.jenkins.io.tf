# Data of resources defined in https://github.com/jenkins-infra/azure-net
data "azurerm_resource_group" "cert_ci_jenkins_io" {
  name = "cert-ci-jenkins-io"
}
data "azurerm_dns_zone" "cert_ci_jenkins_io" {
  name                = "cert.ci.jenkins.io"
  resource_group_name = data.azurerm_resource_group.proddns_jenkinsio.name
}
data "azurerm_virtual_network" "cert_ci_jenkins_io" {
  name                = "cert-ci-jenkins-io-vnet"
  resource_group_name = data.azurerm_resource_group.cert_ci_jenkins_io.name
}
data "azurerm_subnet" "cert_ci_jenkins_io_controller" {
  name                 = "cert-ci-jenkins-io-vnet-controller"
  virtual_network_name = data.azurerm_virtual_network.cert_ci_jenkins_io.name
  resource_group_name  = data.azurerm_resource_group.cert_ci_jenkins_io.name
}
data "azurerm_subnet" "cert_ci_jenkins_io_ephemeral_agents" {
  name                 = "cert-ci-jenkins-io-vnet-ephemeral-agents"
  virtual_network_name = data.azurerm_virtual_network.cert_ci_jenkins_io.name
  resource_group_name  = data.azurerm_resource_group.cert_ci_jenkins_io.name
}

module "cert_ci_jenkins_io" {
  source = "./.shared-tools/terraform/modules/azure-jenkins-controller"

  service_fqdn                 = data.azurerm_dns_zone.cert_ci_jenkins_io.name
  location                     = data.azurerm_resource_group.cert_ci_jenkins_io.location
  admin_username               = local.admin_username
  admin_ssh_publickey          = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDDpxwvySus2OWViWfJ02XMYr+Qa/uPADhjt/4el2SmEf7NlJXzq5vc8imcw8YxQZKwuuKJhonlTYTpk1Cjka4bJKWNOSQ8+Kx0O2ZnNjKn3ZETWJB90bZXHVqbrNHDtu6lN6S/yRW9Q+6fuDbHBW0MXWI8Lsv+bU5v8Zll6m62rc00/I/IT9c1TX1qjCtjf5XHMFw7nVxQiTX2Zf5UKG3RI7mkCMDIvx2H9kXdzM8jtYwATZPHKHuLzffARmvy1FpNPVuLLEGYE3hljP82rll1WZbbl1ZrhjzbFUUYO4fsA7AOQHWhHiVLvtnreB269JOl/ZkHgk37zcdwJMkqKpqoEbjP9z8PURf5uMA7TiDGcpgcFMzoaFk1ueqoHM2JaM2AZQAkPhbUfT7MSOFYRx91OEg5pg5N17zNeaBM6fyxl3v7mkxSOTkKlzjAXPRyo7XsosUVQ4qb4DfsAAJ0Rynts2olRQLEzJku0ZxbbXotuoppI8HivRl7PoTsAASJRpc="
  controller_network_name      = data.azurerm_virtual_network.cert_ci_jenkins_io.name
  controller_network_rg_name   = data.azurerm_resource_group.cert_ci_jenkins_io.name
  controller_subnet_name       = data.azurerm_subnet.cert_ci_jenkins_io_controller.name
  ephemeral_agents_subnet_name = data.azurerm_subnet.cert_ci_jenkins_io_ephemeral_agents.name
  controller_data_disk_size_gb = 128
  controller_vm_size           = "Standard_D2as_v5"
  default_tags                 = local.default_tags

  jenkins_infra_ips = {
    ldap_ipv4           = azurerm_public_ip.ldap_jenkins_io_ipv4.ip_address
    puppet_ipv4         = azurerm_public_ip.puppet_jenkins_io.ip_address
    gpg_keyserver_ipv4s = local.gpg_keyserver_ips["keyserver.ubuntu.com"]
    privatevpn_subnet   = data.azurerm_subnet.private_vnet_data_tier.address_prefixes
  }

  controller_service_principal_ids = [
    data.azuread_service_principal.terraform_production.id,
  ]
  controller_service_principal_end_date = "2024-08-24T12:00:00Z"
  controller_packer_rg_ids = [
    azurerm_resource_group.packer_images["prod"].id
  ]
}
## Service DNS records
resource "azurerm_dns_a_record" "cert_ci_jenkins_io_controller" {
  name                = "controller"
  zone_name           = data.azurerm_dns_zone.cert_ci_jenkins_io.name
  resource_group_name = data.azurerm_dns_zone.cert_ci_jenkins_io.resource_group_name
  ttl                 = 60
  records             = [module.cert_ci_jenkins_io.controller_private_ipv4]
}
resource "azurerm_dns_a_record" "cert_ci_jenkins_io" {
  name                = "@" # Child zone: no CNAME possible!
  zone_name           = data.azurerm_dns_zone.cert_ci_jenkins_io.name
  resource_group_name = data.azurerm_dns_zone.cert_ci_jenkins_io.resource_group_name
  ttl                 = 60
  records             = [module.cert_ci_jenkins_io.controller_private_ipv4]
}

####################################################################################
## NAT gateway to allow outbound connection on a centralized and scalable appliance
####################################################################################
resource "azurerm_public_ip" "cert_ci_jenkins_io_outbound" {
  name                = "cert-ci-jenkins-io-outbound"
  location            = data.azurerm_resource_group.cert_ci_jenkins_io.location
  resource_group_name = module.cert_ci_jenkins_io.controller_resourcegroup_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_nat_gateway" "cert_ci_jenkins_io_outbound" {
  name                = "cert-ci-jenkins-io-outbound"
  location            = data.azurerm_resource_group.cert_ci_jenkins_io.location
  resource_group_name = module.cert_ci_jenkins_io.controller_resourcegroup_name
  sku_name            = "Standard"
}
resource "azurerm_nat_gateway_public_ip_association" "cert_ci_jenkins_io_outbound" {
  nat_gateway_id       = azurerm_nat_gateway.cert_ci_jenkins_io_outbound.id
  public_ip_address_id = azurerm_public_ip.cert_ci_jenkins_io_outbound.id
}
resource "azurerm_subnet_nat_gateway_association" "cert_ci_jenkins_io_outbound_controller" {
  subnet_id      = data.azurerm_subnet.cert_ci_jenkins_io_controller.id
  nat_gateway_id = azurerm_nat_gateway.cert_ci_jenkins_io_outbound.id
}
resource "azurerm_subnet_nat_gateway_association" "cert_ci_jenkins_io_outbound_ephemeral_agents" {
  subnet_id      = data.azurerm_subnet.cert_ci_jenkins_io_ephemeral_agents.id
  nat_gateway_id = azurerm_nat_gateway.cert_ci_jenkins_io_outbound.id
}
