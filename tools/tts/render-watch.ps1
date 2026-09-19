# Box-side state in one shot: is Neiro held off, is the render working, and is
# there anything left to render?
"NEIRO=" + (Get-ScheduledTask -TaskName NeiroBoxPersonaTrain -EA SilentlyContinue).State
"TRAINERS=" + @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*persona_train.py*" }).Count
"RENDER=" + (Get-ScheduledTask -TaskName MMRenderBatch -EA SilentlyContinue).State
"PLANS=" + @(Get-ChildItem "D:\models" -Filter "plan*.json" -EA SilentlyContinue).Count
"DONE=" + @(Get-ChildItem "D:\models" -Recurse -Filter "*.opus" -EA SilentlyContinue).Count
$log = "D:\models\renderbatch.log"
"FINISHED=" + $(if ((Test-Path $log) -and (Select-String -Path $log -SimpleMatch "BATCH_DONE" -Quiet)) { "yes" } else { "no" })
"GPU=" + ((& nvidia-smi --query-gpu=memory.free,utilization.gpu --format=csv,noheader) -join "")
