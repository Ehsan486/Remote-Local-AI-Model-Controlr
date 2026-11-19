# DGGS AI Control Center for Windows (version 1.1)

A native Windows desktop application with clickable buttons that manage your existing local Open WebUI and the llama.cpp model router on the university AMD server.

**No additional GUI installation is required.** This package uses Windows PowerShell 5.1, Windows Forms and the OpenSSH client built into recent Windows versions. The Open WebUI server still requires the `uvx` installation you used previously.

## Launch

1. Connect to the network that provides access to your server, such as Tailscale or a VPN.
2. Clone this repository or extract its full ZIP to a permanent folder on Windows.
3. Double click **`Open_DGGS_Control_Center.vbs`**. This opens the control panel without a terminal window.
4. If VBS scripts are blocked by your Windows security policy, double click **`Open_DGGS_Control_Center.cmd`** instead. That option leaves a visible diagnostic terminal.
5. Open **Settings**, enter your SSH server hostname and username, and click **Save**.
6. The first time only, click **1 Initial Setup**. It opens one temporary console because SSH requires an interactive password and host fingerprint confirmation. Verify the university server's fingerprint independently before accepting the prompt. Press Enter after setup completes to return to the GUI.
7. Click **START EVERYTHING**, or click steps 2 through 6 individually.
8. Choose `dggs-main` or `dggs-uncensored` and press **Load Selected Model**, or just select the model inside Open WebUI and send your first request.
9. When finished, click **STOP MODELS / FREE GPU**. This stops the **managed** service and its child model processes, releasing their VRAM. You may leave Open WebUI running.

The initial setup is the only action that may open a separate console. Normal day-to-day use is entirely through this GUI.

## Buttons

| Button | Effect |
| --- | --- |
| 1 Initial Setup | Once: installs a dedicated SSH key and user systemd service. It does not start any model. |
| 2 Check Connection | Checks VPN/server reachability and SSH authentication. |
| 3 Connect Tunnel | Creates a private SSH tunnel from `127.0.0.1:18080` to the AMD server's `127.0.0.1:8080`. |
| 4 Start Model Server | Starts the llama.cpp model router without preloading weights. |
| 5 Start Open WebUI | Reuses or starts Open WebUI on `http://127.0.0.1:3000`. Reuses existing chat storage. |
| 6 Open Browser | Opens the WebUI. |
| START EVERYTHING | Runs steps 2 through 6 in order. |
| Load Selected Model | Requests router `/models/load` for the chosen model without blocking the GUI. |
| Unload Selected Model | Requests router `/models/unload` to free that model's allocated memory. |
| STOP MODELS / FREE GPU | Stops the systemd **user** service, ending all of its model child processes. Rechecks ROCm status. |
| GPU Status | Reads `rocm-smi` on the server and displays its VRAM percentages. |
| Disconnect Tunnel | Stops only an SSH tunnel created by this Control Center. Does not stop GPU processes. |
| Refresh | Refreshes the model and local service status. |
| Settings | Changes the university SSH hostname and username if needed. |

## Model routing and memory

- Uses `~/dggs-ai/llama.cpp/build-mi100-rocm641/bin/llama-server` with ROCm 6.4.1.
- Model 1: `dggs-main` -> the existing Qwen3.8 Flash Next three shard IQ4_XS model.
- Optional model 2: `dggs-uncensored` -> the model already downloaded under `~/dggs-ai/models/qwen35-uncensored/`.
- The router is configured for **one large model at a time** with a **32,768 token context**.
- It uses idle sleeping after **900 seconds** to return unused weights to RAM/disk when not generating. An explicit **Stop Models** button shuts down the user service to release its GPU allocations immediately.
- The initial setup reads whichever model files actually exist. To add the optional second model later, download its GGUF, then click Initial Setup again to update the router model list.
- Model loading can take a while. The Load Selected Model action runs as a background job and the panel reports completion.

## Important safety rules

- This tool never runs `sudo`, never deletes the model weights, and never uses `killall`, `pkill` or `apt autoremove`.
- It stops only the systemd user service `dggs-llama.service` that was explicitly installed for this workflow.
- GPU VRAM may still be used by other jobs after your model stops. The UI never kills those jobs.
- The university server's SSH connection is private. Your WebUI and model ports bind to Windows localhost and the remote model server binds to server localhost.
- Initial Setup creates an unattended SSH private key **without a passphrase**. Protect your Windows user account, lock your PC, and never copy or share the private key. If your university prohibits unattended SSH keys, do not use this option; contact IT for an approved alternative.
- Your VPN connection is **not** automatically established. The application verifies reachability but does not control Fortinet VPN.
- If `llama-server` is already running manually on remote port 8080, stop that old manual instance **once** before starting the managed service. This application intentionally will not terminate unrelated or manually created processes.
- Closing the Control Center **does not stop** the model server. Click STOP MODELS / FREE GPU before closing if you want to release your allocations.
- The Windows Open WebUI data directory is `%USERPROFILE%\dggs-ai\ui\data` and is never deleted by this application.
- Local logs are stored under `%LOCALAPPDATA%\DGGSControlCenter\logs`.

## Troubleshooting

**The Control Center does not open:** Try the `.cmd` launcher to read the error. Requires Windows PowerShell 5.1 on Windows 10 or 11 with Windows Forms support.

**Step 1 fails:** Make sure the full project is present and your server network is connected; verify the SSH host key; inspect the visible setup console before pressing Enter. The AMD server must permit user systemd sessions. Version 1.1 fixes a Windows PowerShell 5.1 issue where the initial expected `Permission denied (publickey,password)` from the key check was treated as a fatal error and skipped the password installation step. The new setup requests your server password when needed. If it still fails, use a normal PowerShell prompt to test `ssh.exe your-username@gpu-server.example.com` and verify the university account supports password login or ask university IT about SSH key registration.

**Step 4 says port 8080 occupied:** In the existing terminal, stop the old manually launched llama-server with Ctrl+C, then try again. We deliberately do not kill it from the GUI.

**Step 5 fails:** Make sure `uvx.exe` is installed on Windows. Inspect `open-webui-error.log` in the local log folder. If you already have Open WebUI running on port 3000, the panel reuses it.

**Open WebUI displays no models:** In Open WebUI, Admin > Connections, check the OpenAI compatible API base URL `http://127.0.0.1:18080/v1`, then refresh the model list. Select `dggs-main` or `dggs-uncensored` if present.

**Model load fails:** Inspect the Control Center log and the server logs with `journalctl --user -u dggs-llama.service` when debugging. The second model must already exist at its configured path.

**Stop Models succeeds but VRAM is not zero:** Other processes may be using the GPUs, or ROCm memory reporting may lag. The button stops only your managed service.

## Testing and limitations

The Linux service installer has been exercised in a simulated environment, and all shipped shell scripts passed `bash -n`. The PowerShell GUI has been structurally checked, but this environment cannot execute Windows Forms or connect to your university server. Its actual button behaviour must be confirmed on your Windows PC. No actual VPN connection, model download or GPU job was initiated by this package.

Official references:
- [llama.cpp router, model load and unload API](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Open WebUI Windows and uv installation](https://docs.openwebui.com/getting-started/quick-start/)
