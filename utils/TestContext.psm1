class TestContext {
    # Properties
    [String] $Policy
    [String] $PolicyFile
    [PSObject] $PolicyDefinition
    [PSObject] $PolicyAssignment
    [PSObject] $PolicyParameterObject
    [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup] $ResourceGroup
    [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription] $Subscription
    [String] $Location
}