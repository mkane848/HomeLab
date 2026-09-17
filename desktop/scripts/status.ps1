# status.ps1 — Check desktop-side service status

Write-Host ""
Write-Host "=== Desktop Services Status ===" -ForegroundColor Cyan
Write-Host ""

# Check Ollama process
$ollamaProcess = Get-Process ollama -ErrorAction SilentlyContinue
if ($ollamaProcess) {
    Write-Host "Ollama Process: RUNNING (PID: $($ollamaProcess.Id))" -ForegroundColor Green
} else {
    Write-Host "Ollama Process: NOT RUNNING" -ForegroundColor Red
}
Write-Host ""

# Check API
Write-Host "--- Ollama API ---"
try {
    $response = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5
    Write-Host "Ollama API: UP (http://localhost:11434)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Loaded models:"
    $response.models | ForEach-Object {
        Write-Host "  - $($_.name) (size: $([math]::Round($_.size / 1GB, 1)) GB)"
    }
} catch {
    Write-Host "Ollama API: DOWN or not responding" -ForegroundColor Red
}
