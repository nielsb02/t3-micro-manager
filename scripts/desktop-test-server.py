import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time

root = Path(sys.argv[1])
digest = hashlib.sha256(b"/Users/test/.t3/userdata").hexdigest()[:24]
(root / "expected-path").write_text(f"/tmp/t3code-501/{digest}.sock")
(root / "server-pid").write_text(str(os.getpid()))
micro_actions = ["dial-clockwise", "dial-counterclockwise", "dial-press", "composer-toggle",
                 "new-thread", "new-project", "latest-message", "settle-thread", "terminal-toggle", "command-palette"]


def serve(mode, server):
    with server:
        if mode == "delayed":
            while not (root / "start-delayed").exists():
                time.sleep(0.01)
            time.sleep(0.15)
            server.bind(str(root / f"{mode}.sock"))
            server.listen()
        connection, _ = server.accept()
        with connection:
            line = connection.makefile("rb").readline(65537)
            if mode == "wrong-peer":
                assert not line, "Client sent a session to the wrong app before checking its PID"
                return
            request = json.loads(line)
            if mode in micro_actions:
                assert request == dict(version=1, requestId=request["requestId"], type="micro-control", action=mode)
                response = dict(version=1, requestId=request["requestId"], ok=True, action=mode)
                connection.sendall(json.dumps(response).encode() + b"\n")
                return
            if mode == "wait":
                connection.recv(1)
                return
            assert request["version"] == 1 and request["type"] == "open-thread"
            assert request["environmentId"] == "target-environment"
            assert request["threadId"] == "thread/with space 雪"
            assert "bearerToken" not in request and "title" not in request
            response = dict(version=1, requestId=request["requestId"], ok=True,
                            environmentId=request["environmentId"], threadId=request["threadId"], projectId="p")
            if mode == "id":
                response["requestId"] = "different-request"
            elif mode == "env":
                response["environmentId"] = "different-environment"
            elif mode == "thread":
                response["threadId"] = "different-thread"
            elif mode == "old":
                del response["environmentId"]
            elif mode == "reject":
                response = dict(version=1, requestId=request["requestId"], ok=False,
                                code="thread-open-failed", message="Session is unavailable.")
            elif mode == "closed":
                return
            elif mode == "large":
                try:
                    connection.sendall(b"x" * 70000)
                except BrokenPipeError:
                    pass
                return
            encoded = json.dumps(response).encode() + b"\n"
            connection.sendall(encoded[:7])
            connection.sendall(encoded[7:])


workers = []
for mode in ["ok", "id", "env", "thread", "old", "reject", "closed", "large", "wait", "peer", "wrong-peer", "delayed"] + micro_actions:
    listener = socket.socket(socket.AF_UNIX)
    if mode != "delayed":
        listener.bind(str(root / f"{mode}.sock"))
        listener.listen()
    worker = threading.Thread(target=serve, args=(mode, listener))
    worker.start()
    workers.append(worker)
(root / "ready").touch()
for worker in workers:
    worker.join()
