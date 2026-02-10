#!/usr/bin/env python3
"""
Molten Bridge - Lightweight subprocess bridge for molten-nvim.

This script manages Jupyter kernels and communicates with Lua over stdio using JSON lines.
It replaces the pynvim remote plugin architecture with a simpler subprocess model.

Protocol:
- Reads JSON commands from stdin (one per line)
- Writes JSON responses/events to stdout (one per line)
- Uses stderr for logging/debugging only

Commands (stdin):
- {"cmd": "start_kernel", "id": "req1", "kernel_name": "python3"}
- {"cmd": "execute", "id": "req2", "kernel_id": "...", "code": "print('hello')"}
- {"cmd": "interrupt", "id": "req3", "kernel_id": "..."}
- {"cmd": "restart", "id": "req4", "kernel_id": "..."}
- {"cmd": "shutdown", "id": "req5", "kernel_id": "..."}
- {"cmd": "list_kernels", "id": "req6"}
- {"cmd": "input_reply", "id": "req7", "kernel_id": "...", "value": "user input"}
- {"cmd": "is_ready", "id": "req8", "kernel_id": "..."}

Responses/Events (stdout):
- {"type": "response", "id": "req1", "success": true, "kernel_id": "...", ...}
- {"type": "event", "kernel_id": "...", "msg_type": "...", "content": {...}}
- {"type": "error", "id": "req1", "message": "..."}
"""

import sys
import json
import select
import tempfile
import os
from typing import Dict, Any, Optional, List
from queue import Empty as EmptyQueueException

import jupyter_client
from jupyter_client import KernelManager


class KernelInfo:
    """Tracks a single kernel's manager and client."""
    
    def __init__(self, kernel_id: str, manager: KernelManager, client):
        self.kernel_id = kernel_id
        self.manager = manager
        self.client = client
        self.allocated_files: List[str] = []
        self.external = False  # Whether this is an external kernel connection
        
    def cleanup(self):
        """Clean up resources for this kernel."""
        for path in self.allocated_files:
            if os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass
        
        if not self.external:
            try:
                self.client.stop_channels()
                self.manager.shutdown_kernel()
            except Exception:
                pass


class MoltenBridge:
    """Main bridge class that manages multiple kernels."""
    
    def __init__(self):
        self.kernels: Dict[str, KernelInfo] = {}
        self.running = True
        
    def log(self, message: str):
        """Log to stderr for debugging."""
        print(f"[Bridge] {message}", file=sys.stderr, flush=True)
    
    def send_response(self, req_id: str, success: bool, **kwargs):
        """Send a response to a command."""
        response = {
            "type": "response",
            "id": req_id,
            "success": success,
            **kwargs
        }
        print(json.dumps(response), flush=True)
    
    def send_error(self, req_id: str, message: str):
        """Send an error response."""
        error = {
            "type": "error",
            "id": req_id,
            "message": message
        }
        print(json.dumps(error), flush=True)
    
    def send_event(self, kernel_id: str, msg_type: str, content: Dict[str, Any], 
                   parent_header: Optional[Dict[str, Any]] = None):
        """Send a kernel event."""
        event = {
            "type": "event",
            "kernel_id": kernel_id,
            "msg_type": msg_type,
            "content": content
        }
        if parent_header:
            event["parent_header"] = parent_header
        print(json.dumps(event), flush=True)
    
    def handle_command(self, cmd: Dict[str, Any]):
        """Handle a command from stdin."""
        cmd_type = cmd.get("cmd")
        req_id = cmd.get("id", "unknown")
        
        try:
            if cmd_type == "start_kernel":
                self.cmd_start_kernel(req_id, cmd)
            elif cmd_type == "execute":
                self.cmd_execute(req_id, cmd)
            elif cmd_type == "interrupt":
                self.cmd_interrupt(req_id, cmd)
            elif cmd_type == "restart":
                self.cmd_restart(req_id, cmd)
            elif cmd_type == "shutdown":
                self.cmd_shutdown(req_id, cmd)
            elif cmd_type == "list_kernels":
                self.cmd_list_kernels(req_id, cmd)
            elif cmd_type == "input_reply":
                self.cmd_input_reply(req_id, cmd)
            elif cmd_type == "is_ready":
                self.cmd_is_ready(req_id, cmd)
            elif cmd_type == "quit":
                self.running = False
                self.send_response(req_id, True)
            else:
                self.send_error(req_id, f"Unknown command: {cmd_type}")
        except Exception as e:
            self.log(f"Error handling command {cmd_type}: {e}")
            self.send_error(req_id, str(e))
    
    def cmd_start_kernel(self, req_id: str, cmd: Dict[str, Any]):
        """Start a new kernel."""
        kernel_name = cmd.get("kernel_name", "python3")
        
        # Check if this is an external kernel connection (JSON file or HTTP URL)
        if kernel_name.startswith("http://") or kernel_name.startswith("https://"):
            self.send_error(req_id, "HTTP kernel connections not yet implemented in bridge")
            return
        elif ".json" in kernel_name:
            # External kernel connection via JSON file
            try:
                with open(kernel_name) as f:
                    kernel_json = json.load(f)
                manager = KernelManager(kernel_name=kernel_json.get("kernel_name", "python3"))
                client = manager.client()
                client.load_connection_file(connection_file=kernel_name)
                kernel_id = os.path.basename(kernel_name)
                
                kernel_info = KernelInfo(kernel_id, manager, client)
                kernel_info.external = True
                self.kernels[kernel_id] = kernel_info
                
                self.send_response(req_id, True, kernel_id=kernel_id, 
                                 connection_file=kernel_name)
            except Exception as e:
                self.send_error(req_id, f"Failed to connect to external kernel: {e}")
            return
        
        # Start a new local kernel
        try:
            manager = KernelManager(kernel_name=kernel_name)
            manager.start_kernel()
            client = manager.client()
            client.start_channels()
            
            # Generate kernel ID
            kernel_id = manager.kernel_id or f"{kernel_name}_{id(manager)}"
            
            # Get connection file path
            connection_file = None
            if hasattr(client, 'connection_file'):
                connection_file = client.connection_file
            elif hasattr(manager, 'connection_file'):
                connection_file = manager.connection_file
            
            kernel_info = KernelInfo(kernel_id, manager, client)
            self.kernels[kernel_id] = kernel_info
            
            self.send_response(req_id, True, kernel_id=kernel_id, 
                             connection_file=connection_file or "")
        except Exception as e:
            self.send_error(req_id, f"Failed to start kernel: {e}")
    
    def cmd_execute(self, req_id: str, cmd: Dict[str, Any]):
        """Execute code in a kernel."""
        kernel_id = cmd.get("kernel_id")
        code = cmd.get("code", "")
        
        if kernel_id not in self.kernels:
            self.send_error(req_id, f"Kernel not found: {kernel_id}")
            return
        
        try:
            kernel_info = self.kernels[kernel_id]
            msg_id = kernel_info.client.execute(code)
            self.send_response(req_id, True, msg_id=msg_id)
        except Exception as e:
            self.send_error(req_id, f"Failed to execute code: {e}")
    
    def cmd_interrupt(self, req_id: str, cmd: Dict[str, Any]):
        """Interrupt a kernel."""
        kernel_id = cmd.get("kernel_id")
        
        if kernel_id not in self.kernels:
            self.send_error(req_id, f"Kernel not found: {kernel_id}")
            return
        
        try:
            kernel_info = self.kernels[kernel_id]
            kernel_info.manager.interrupt_kernel()
            self.send_response(req_id, True)
        except Exception as e:
            self.send_error(req_id, f"Failed to interrupt kernel: {e}")
    
    def cmd_restart(self, req_id: str, cmd: Dict[str, Any]):
        """Restart a kernel."""
        kernel_id = cmd.get("kernel_id")
        
        if kernel_id not in self.kernels:
            self.send_error(req_id, f"Kernel not found: {kernel_id}")
            return
        
        try:
            kernel_info = self.kernels[kernel_id]
            kernel_info.manager.restart_kernel()
            self.send_response(req_id, True)
        except Exception as e:
            self.send_error(req_id, f"Failed to restart kernel: {e}")
    
    def cmd_shutdown(self, req_id: str, cmd: Dict[str, Any]):
        """Shutdown a kernel."""
        kernel_id = cmd.get("kernel_id")
        
        if kernel_id not in self.kernels:
            self.send_error(req_id, f"Kernel not found: {kernel_id}")
            return
        
        try:
            kernel_info = self.kernels[kernel_id]
            kernel_info.cleanup()
            del self.kernels[kernel_id]
            self.send_response(req_id, True)
        except Exception as e:
            self.send_error(req_id, f"Failed to shutdown kernel: {e}")
    
    def cmd_list_kernels(self, req_id: str, cmd: Dict[str, Any]):
        """List available kernel specs."""
        try:
            specs = jupyter_client.kernelspec.find_kernel_specs()
            kernel_names = list(specs.keys())
            self.send_response(req_id, True, kernels=kernel_names)
        except Exception as e:
            self.send_error(req_id, f"Failed to list kernels: {e}")
    
    def cmd_input_reply(self, req_id: str, cmd: Dict[str, Any]):
        """Send input reply to a kernel."""
        kernel_id = cmd.get("kernel_id")
        value = cmd.get("value", "")
        
        if kernel_id not in self.kernels:
            self.send_error(req_id, f"Kernel not found: {kernel_id}")
            return
        
        try:
            kernel_info = self.kernels[kernel_id]
            kernel_info.client.input(value)
            self.send_response(req_id, True)
        except Exception as e:
            self.send_error(req_id, f"Failed to send input: {e}")
    
    def cmd_is_ready(self, req_id: str, cmd: Dict[str, Any]):
        """Check if a kernel is ready."""
        kernel_id = cmd.get("kernel_id")
        
        if kernel_id not in self.kernels:
            self.send_error(req_id, f"Kernel not found: {kernel_id}")
            return
        
        try:
            kernel_info = self.kernels[kernel_id]
            kernel_info.client.wait_for_ready(timeout=0)
            self.send_response(req_id, True, ready=True)
        except RuntimeError:
            self.send_response(req_id, True, ready=False)
        except Exception as e:
            self.send_error(req_id, f"Failed to check readiness: {e}")
    
    def poll_messages(self):
        """Poll all kernels for messages and send events."""
        for kernel_id, kernel_info in list(self.kernels.items()):
            # Poll IOPub messages
            while True:
                try:
                    msg = kernel_info.client.get_iopub_msg(timeout=0)
                    if "content" in msg and "msg_type" in msg:
                        # Handle image data by writing to temp files
                        content = msg["content"].copy()
                        if msg["msg_type"] in ("display_data", "execute_result"):
                            data = content.get("data", {})
                            for mime_type in ("image/png", "image/jpeg", "image/svg+xml"):
                                if mime_type in data:
                                    # Write image to temp file
                                    if mime_type == "image/svg+xml":
                                        ext = "svg"
                                        mode = "w"
                                    else:
                                        ext = mime_type.split("/")[1]
                                        mode = "wb"
                                    
                                    with tempfile.NamedTemporaryFile(
                                        suffix=f".{ext}", mode=mode, delete=False
                                    ) as f:
                                        if mime_type == "image/svg+xml":
                                            f.write(data[mime_type])
                                        else:
                                            import base64
                                            f.write(base64.b64decode(data[mime_type]))
                                        temp_path = f.name
                                    
                                    kernel_info.allocated_files.append(temp_path)
                                    content["data"] = content.get("data", {}).copy()
                                    content["data"][f"{mime_type}_path"] = temp_path
                        
                        self.send_event(kernel_id, msg["msg_type"], content, 
                                      msg.get("parent_header"))
                except EmptyQueueException:
                    break
                except Exception as e:
                    self.log(f"Error polling IOPub for {kernel_id}: {e}")
                    break
            
            # Poll stdin messages
            try:
                msg = kernel_info.client.get_stdin_msg(timeout=0)
                if msg and "msg_type" in msg:
                    self.send_event(kernel_id, msg["msg_type"], msg.get("content", {}))
            except EmptyQueueException:
                pass
            except Exception as e:
                self.log(f"Error polling stdin for {kernel_id}: {e}")
    
    def run(self):
        """Main event loop."""
        self.log("Bridge started")
        
        while self.running:
            # Use select to wait for either stdin input or timeout
            readable, _, _ = select.select([sys.stdin], [], [], 0.1)
            
            if readable:
                try:
                    line = sys.stdin.readline()
                    if not line:
                        # EOF on stdin
                        break
                    
                    cmd = json.loads(line.strip())
                    self.handle_command(cmd)
                except json.JSONDecodeError as e:
                    self.log(f"Invalid JSON: {e}")
                except Exception as e:
                    self.log(f"Error reading command: {e}")
            
            # Poll all kernels for messages
            self.poll_messages()
        
        # Cleanup on exit
        self.log("Bridge shutting down")
        for kernel_info in list(self.kernels.values()):
            kernel_info.cleanup()


if __name__ == "__main__":
    bridge = MoltenBridge()
    try:
        bridge.run()
    except KeyboardInterrupt:
        pass
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        sys.exit(1)
