Import-Module -Name Az.Network
Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/../utils/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Rest.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/RouteTable.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Test.Utils.psm1" -Force

Describe "Testing policy 'Audit-Route-NextHopVirtualAppliance'" -Tag "audit-route-nexthopvirtualappliance" {
    Context "When auditing route tables" {
        It "Should mark route table as compliant with route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-compliant" {
            AzTest -ResourceGroup {
                param($ResourceGroup)

                # Create compliant route table
                $route = New-AzRouteConfig `
                    -Name "default" `
                    -AddressPrefix "0.0.0.0/0" `
                    -NextHopType "VirtualAppliance" `
                    -NextHopIpAddress (Get-VirtualApplianceIpAddress -Location $ResourceGroup.Location)
                
                
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $ResourceGroup.ResourceGroupName `
                    -Location $ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion
                $ResourceGroup | Complete-PolicyComplianceScan 

                # Verify that network security group is incompliant
                $routeTable 
                | Get-PolicyComplianceState -PolicyDefinition "Audit-Route-NextHopVirtualAppliance"
                | Should -BeTrue
            }
        }

        It "Should mark route table as incompliant without route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-incompliant" {
            AzTest -ResourceGroup {
                param($ResourceGroup)

                # Create incompliant route table by deleting route 0.0.0.0/0 pointing to the virtual appliance
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $ResourceGroup.ResourceGroupName `
                    -Location $ResourceGroup.Location `
                    -Route $Route

                $route = Get-RouteNextHopVirtualAppliance -RouteTable $RouteTable

                $routeTable | Invoke-RouteDelete -Route $route

                # Trigger compliance scan for resource group and wait for completion
                $ResourceGroup | Complete-PolicyComplianceScan 

                # Verify that network security group is incompliant
                $routeTable 
                | Get-PolicyComplianceState -PolicyDefinition "Audit-Route-NextHopVirtualAppliance"
                | Should -BeFalse
            }
        }
    }
}