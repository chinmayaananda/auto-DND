@{
    ExcludeRules = @(
        # Write-Host is the correct channel for the interactive -Once and diagnostic
        # paths; those exist to be read by a human at a console.
        'PSAvoidUsingWriteHost'

        # The internal suppression helpers are called only from the watcher loop, which
        # already gates every registry write behind Set-NotificationsEnabled's
        # -WhatIf support and the script-level -NoAct switch.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
