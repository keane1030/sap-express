param location string = resourceGroup().location
param vmName string = 'sap-hxe-vm'
param adminUsername string = 'azureuser'
@secure()
param adminPassword string

param vmSize string = 'Standard_E8s_v5' // SAP‑capable x64 VM

// -----------------------------
// Networking
// -----------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'sap-hxe-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.10.1.0/24'
        }
      }
    ]
  }
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
  }
}

// -----------------------------
// Virtual Machine
// -----------------------------
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'SUSE'
        offer: 'sles-sap-15-sp5'
        sku: 'gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// -----------------------------
// Custom Script Extension
// Installs SAP HANA Express
// -----------------------------
resource hxeInstall 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  name: '${vmName}/hxeInstall'
  location: location
  dependsOn: [
    vm
  ]
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        // Replace with your storage account URL containing the installer + script
        'https://<yourstorage>.blob.core.windows.net/hxe/install-hxe.sh'
      ]
      commandToExecute: 'bash install-hxe.sh'
    }
  }
}
