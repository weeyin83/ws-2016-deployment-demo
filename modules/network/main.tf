############################################
# modules/network - one VNet, one subnet, one NSG shared by all VMs
############################################

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "address_space" {
  type = list(string)
}

variable "subnet_name" {
  type = string
}

variable "subnet_prefix" {
  type = list(string)
}

variable "nsg_name" {
  type = string
}

variable "rdp_rules" {
  description = "Map of vm_key => { source_cidr } for VMs that have public RDP enabled. Generates one scoped inbound allow rule per VM."
  type = map(object({
    source_cidr = string
  }))
  default = {}
}

variable "tags" {
  type = map(string)
}

resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "main" {
  name                 = var.subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.subnet_prefix
}

# Single NSG applied at the subnet level (simplest reliable option for 5 VMs
# sharing one subnet - avoids 5 near-identical per-NIC NSGs).
resource "azurerm_network_security_group" "main" {
  name                = var.nsg_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# One scoped inbound RDP allow rule per VM that opted into public RDP, each
# restricted to its own trusted source CIDR. No rule at all is created for
# any other VM - default NSG behaviour already denies inbound from the
# internet, so "no rule" is the secure default.
resource "azurerm_network_security_rule" "rdp" {
  for_each = var.rdp_rules

  name                        = "Allow-RDP-${each.key}"
  priority                    = 1000 + index(keys(var.rdp_rules), each.key)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = each.value.source_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.main.name
}

# NOTE: no custom outbound rules are added. Azure's default NSG rules
# (AllowVnetOutBound / AllowInternetOutBound) already permit the outbound
# HTTPS (443) traffic required for Azure Arc agent download/onboarding, ARM,
# and Microsoft Entra authentication. IMDS/WireServer link-local traffic
# (169.254.169.254 / .253) bypasses NSGs entirely (handled by the Azure
# hypervisor), so blocking it is done at the guest OS firewall level instead
# - see modules/arc-onboarding and scripts/Prepare-ArcEvaluationVm.ps1.

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "subnet_id" {
  value = azurerm_subnet.main.id
}

output "nsg_id" {
  value = azurerm_network_security_group.main.id
}
