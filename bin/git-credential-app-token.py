#!/usr/bin/env python3
"""Git credential helper that generates GitHub App installation tokens.
Usage: git config credential.helper '/path/to/git-credential-app-token.py'
Only responds to github.com requests. Generates a short-lived token
from the AetherClaude GitHub App installation."""
import sys, json, time, os, base64

def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ''
    if action != 'get':
        return

    # Read stdin for credential request
    lines = {}
    for line in sys.stdin:
        line = line.strip()
        if not line:
            break
        if '=' in line:
            k, v = line.split('=', 1)
            lines[k] = v

    if lines.get('host') != 'github.com':
        return

    # Load config
    env = {}
    for line in open(os.environ.get('AGENT_HOME', '/home/aetherclaude') + '/.env'):
        if '=' in line and not line.startswith('#'):
            k, v = line.strip().split('=', 1)
            env[k] = v

    app_id = env.get('GITHUB_APP_ID', '')
    pk = open(os.environ.get('AGENT_HOME', '/home/aetherclaude') + '/.github-app-key.pem').read()

    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    import urllib.request

    now = int(time.time())
    header = base64.urlsafe_b64encode(json.dumps({'alg':'RS256','typ':'JWT'}).encode()).rstrip(b'=').decode()
    payload = base64.urlsafe_b64encode(json.dumps({'iat':now-60,'exp':now+600,'iss':app_id}).encode()).rstrip(b'=').decode()
    key = serialization.load_pem_private_key(pk.encode(), password=None)
    sig = key.sign((header + '.' + payload).encode(), padding.PKCS1v15(), hashes.SHA256())
    sig_b64 = base64.urlsafe_b64encode(sig).rstrip(b'=').decode()
    jwt_token = header + '.' + payload + '.' + sig_b64

    proxy = env.get('HTTPS_PROXY', 'http://127.0.0.1:8888')
    proxy_handler = urllib.request.ProxyHandler({'https': proxy})
    opener = urllib.request.build_opener(proxy_handler)

    # Find the AetherClaude installation (for fork pushes)
    req = urllib.request.Request('https://api.github.com/app/installations',
        headers={'Authorization': 'Bearer ' + jwt_token, 'Accept': 'application/vnd.github+json', 'User-Agent': os.environ.get('FORK_OWNER', 'your-fork-org')})
    installs = json.loads(opener.open(req).read())

    # Find installation for AetherClaude account (the fork owner)
    install_id = None
    for inst in installs:
        if inst['account']['login'] == os.environ.get('FORK_OWNER', 'your-fork-org'):
            install_id = inst['id']
            break

    if not install_id:
        # Fallback to first installation
        install_id = installs[0]['id']

    # Generate installation token
    req2 = urllib.request.Request(
        'https://api.github.com/app/installations/' + str(install_id) + '/access_tokens',
        method='POST',
        headers={'Authorization': 'Bearer ' + jwt_token, 'Accept': 'application/vnd.github+json', 'User-Agent': os.environ.get('FORK_OWNER', 'your-fork-org')})
    token_data = json.loads(opener.open(req2).read())

    print('protocol=https')
    print('host=github.com')
    print('username=x-access-token')
    print('password=' + token_data['token'])

if __name__ == '__main__':
    main()
