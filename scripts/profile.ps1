function prompt { "PS [$env:COMPUTERNAME]:$($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
if (Test-Path "c:\enableDebugging") {
    $DebugPreference = "Continue"
}