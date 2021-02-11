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

                # Create compliant route table.
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

                # Trigger compliance scan for resource group and wait for completion.
                $ResourceGroup | Complete-PolicyComplianceScan 

                # Verify that route table is compliant.
                $routeTable 
                | Get-PolicyComplianceState -PolicyDefinitionName "Audit-Route-NextHopVirtualAppliance"
                | Should -BeTrue
            }
        }

        It "Should mark route table as incompliant without route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-incompliant" {
            AzTest -ResourceGroup {
                param($ResourceGroup)

                # Create incompliant route table by deleting route 0.0.0.0/0 pointing to the virtual appliance.
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $ResourceGroup.ResourceGroupName `
                    -Location $ResourceGroup.Location `
                    -Route $Route

                # Get route 0.0.0.0/0 pointing to the virtual appliance, which was added by policy.
                $route = Get-RouteNextHopVirtualAppliance -RouteTable $RouteTable

                # Remove-AzRouteConfig/Set-AzRouteTable will issue a PUT request for routeTables and hence policy might kick in.
                # In order to delete the route without policy interfering, directly call the REST API by issuing a DELETE request for route.
                $routeTable | Invoke-RouteDelete -Route $route

                # Trigger compliance scan for resource group and wait for completion.
                $ResourceGroup | Complete-PolicyComplianceScan 

                # Verify that route table is incompliant.
                $routeTable 
                | Get-PolicyComplianceState -PolicyDefinitionName "Audit-Route-NextHopVirtualAppliance"
                | Should -BeFalse
            }
        }
    }
}
