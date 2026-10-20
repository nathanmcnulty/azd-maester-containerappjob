"""Offline child probe for the publisher; never calls Azure or prints credentials.

Models the relevant Azure CLI validate_client_parameters / Knack precedence:
explicit auth mode and account win, but a configured connection string replaces
account and key unless the environment provides an actual empty override.
"""
import configparser
import os
import sys
from pathlib import Path

args = sys.argv[1:]
config = configparser.ConfigParser()
config.read(Path(os.environ['AZURE_CONFIG_DIR']) / 'config')

def setting(name):
    return os.environ.get('AZURE_STORAGE_' + name.upper(), config.get('storage', name))

def argument(name):
    return args[args.index(name) + 1]

assert '--account-key' not in args
assert 'fixture-secret-key' not in ' '.join(args)
assert setting('connection_string') == ''
assert 'AZURE_STORAGE_CONNECTION_STRING' in os.environ
account = argument('--account-name')
key = setting('key')
connection = setting('connection_string')
if connection:
    fields = dict(part.split('=', 1) for part in connection.split(';'))
    account, key = fields['AccountName'], fields['AccountKey']
assert account == 'test'
assert key == 'fixture-secret-key'
assert argument('--auth-mode') == 'key'
assert argument('--share-name') == 'scripts'
assert argument('--subscription') == '11111111-1111-4111-8111-111111111111'

# Exercise suppression of untrusted child diagnostics on both native streams.
print("native diagnostic fixture-secret-key")
print("native diagnostic fixture-secret-key", file=sys.stderr)
