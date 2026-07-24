// =============================================================================
// Project 2 — Secured Storage Account with Private Endpoint
// -----------------------------------------------------------------------------
// Recreates the full portal build as Infrastructure as Code.
// Dependency chain:
//   VNet + subnet
//     └── Storage account (publicNetworkAccess: 'Disabled')
//           └── Private endpoint (sub-resource: blob)
//                 └── Private DNS zone (privatelink.blob.core.windows.net)
//                       └── VNet link + DNS zone group (auto A-record)
//
// Deploy:
//   az group create --name rg-storage-project2 --location westeurope
//   az deployment group create \
//     --resource-group rg-storage-project2 \
//     --template-file main.bicep
// =============================================================================

// ------------------------- Parameters --------------------------------------
@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Globally-unique storage account name (3-24 chars, lowercase + numbers).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stproject2spas'

@description('Name of the virtual network.')
param vnetName string = 'vnet-project2'

@description('Name of the workload subnet that hosts the private endpoint.')
param subnetName string = 'snet-workload'

@description('Name of the private endpoint.')
param privateEndpointName string = 'pe-storage-project2'

@description('Name of the blob container to create.')
param containerName string = 'data'

// The Private DNS zone name is FIXED by Azure for blob private endpoints.
var privateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var privateEndpointNicName = '${privateEndpointName}-nic'

// ------------------------- Virtual Network ---------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.10.1.0/24'
          // Required so a private endpoint NIC can be placed in this subnet.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ------------------------- Storage Account ---------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS' // cheapest for lab; use ZRS/GRS/GZRS in production
  }
  kind: 'StorageV2'
  properties: {
    // The whole point of the project: no public internet access.
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false // block anonymous blob access
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Blob service with versioning enabled (storage governance bonus).
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: true
  }
}

// A container to store blobs (private access only).
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle management: cool tier after 30 days, delete after 365 days.
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'tier-then-delete'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
                delete: {
                  daysAfterModificationGreaterThan: 365
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ------------------------- Private DNS Zone --------------------------------
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global' // Private DNS zones are always global
}

// Link the DNS zone to the VNet so VMs inside resolve to the private IP.
resource dnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ------------------------- Private Endpoint --------------------------------
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${subnetName}'
    }
    customNetworkInterfaceName: privateEndpointNicName
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob' // one private endpoint per sub-resource (blob/file/queue/table)
          ]
        }
      }
    ]
  }
}

// DNS zone group: auto-creates the A-record mapping the storage name -> private IP.
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-config'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// ------------------------- Outputs -----------------------------------------
output storageAccountId string = storageAccount.id
output storageAccountBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output privateEndpointId string = privateEndpoint.id
output privateDnsZoneName string = privateDnsZone.name
