# Load dotenv into current PowerShell session (ignores comments/empty lines, supports optional `export` prefix)
# - Accepts simple KEY=VALUE pairs
# - Supports values quoted with single or double quotes
# - Strips inline comments (unquoted) starting with '#'

Get-Content ../.env -ErrorAction Stop | ForEach-Object {
    $line = $_.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        return
    }

    # support lines like: export KEY=VALUE
    $line = $line -replace '^[\s]*export[\s]+', ''

    # split on the first '=' only
    $pair = $line -split '=', 2
    if ($pair.Length -ne 2) { return }

    $name = $pair[0].Trim()
    $rawValue = $pair[1].Trim()

    # If value is quoted with double quotes
    if ($rawValue -match '^[\s]*"(.*)"[\s]*$') {
        $value = $matches[1]
    }
    # If value is quoted with single quotes
    elseif ($rawValue -match "^[\s]*'(.*)'[\s]*$") {
        $value = $matches[1]
    }
    else {
        # remove inline comment starting with '#' (naive: good for typical .env usage)
        $idx = $rawValue.IndexOf('#')
        if ($idx -ge 0) {
            $value = $rawValue.Substring(0, $idx).Trim()
        }
        else {
            $value = $rawValue
        }
    }

    # Final trim of surrounding whitespace and quotes if any
    $value = $value.Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    if ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    # Set environment variable for current process and child processes using .NET API to avoid variable-name parsing issues
    [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
}
