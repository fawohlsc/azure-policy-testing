Import-Module -Name Az.Network
Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/../utils/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Rest.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/RouteTable.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Test.Utils.psm1" -Force

Describe "Testing policy 'Audit-Route-NextHopVirtualAppliance'" -Tag "audit-route-nexthopvirtualappliance" {
    BeforeAll {
        $script:PolicyDefinitionName = "Audit-Route-NextHopVirtualAppliance"
        
        $script:PolicyParameterObject = @{
            "routeTableSettings" = @{
                "northeurope" = @{
                    "virtualApplianceIpAddress" = "10.0.0.23"
                }; 
                "disabled"    = @{
                    "virtualApplianceIpAddress" = ""
                }
            }
        }
    }
    
    Context "When auditing route tables" {
        It "Should mark route table as compliant with route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-compliant" {
            AzPolicyTest -PolicyDefinitionName $script:PolicyDefinitionName -PolicyParameterObject $script:PolicyParameterObject {
                param($TestContext)

                # Create compliant route table with route 0.0.0.0/0 pointing to the virtual appliance.
                $route = New-AzRouteConfig `
                    -Name "default" `
                    -AddressPrefix "0.0.0.0/0" `
                    -NextHopType "VirtualAppliance" `
                    -NextHopIpAddress (Get-VirtualApplianceIpAddress -Location $TestContext.ResourceGroup.Location)
                                
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                $TestContext.ResourceGroup | Complete-PolicyComplianceScan 

                # Verify that route table is compliant.
                $routeTable 
                | Get-PolicyComplianceState -PolicyDefinitionName $TestContext.PolicyDefinitionName
                | Should -BeTrue
            }
        }

        It "Should mark route table as incompliant without route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-incompliant" {
            AzPolicyTest -PolicyDefinitionName $script:PolicyDefinitionName -PolicyParameterObject $script:PolicyParameterObject {
                param($TestContext)

                # Create incompliant route table without route 0.0.0.0/0 pointing to the virtual appliance.
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                $TestContext.ResourceGroup | Complete-PolicyComplianceScan 

                # Verify that route table is incompliant.
                $routeTable 
                | Get-PolicyComplianceState -PolicyDefinitionName $TestContext.PolicyDefinitionName
                | Should -BeFalse
            }
        }
    }
}
