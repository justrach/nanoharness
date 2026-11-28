#!/usr/bin/env python3
"""Synthetic ACP stdio agent. All state lives in the test's scratch cwd."""
import json
import pathlib
import sys

mode = pathlib.Path('mode').read_text()
version = None
session_id = 'synthetic-session'
message_id = 'synthetic-user'

def write(value):
    print(json.dumps({'jsonrpc': '2.0', **value}), flush=True)

def record(*fields):
    with open('traffic', 'a') as out:
        print(*fields, file=out)

def update(session, tag, **fields):
    write({'method': 'session/update', 'params': {'sessionId': session,
           'update': {'sessionUpdate': tag, **fields}}})

for line in sys.stdin:
    req = json.loads(line)
    if 'method' not in req:
        record('client-response', req['id'], json.dumps(req['result'], sort_keys=True))
        if req['id'] == 'owned-form':
            update(session_id, 'state_update', state='idle', stopReason='end_turn')
            update(session_id, 'state_update', state='idle', background=[])
        continue
    method = req['method']
    params = req.get('params', {})
    result = {}
    if method == 'initialize':
        assert version is None, 'requires a fresh stdio child'
        version = params['protocolVersion']
        record('initialize', version)
        if version == 2:
            assert params['info']['name'] == 'harness'
            assert 'clientCapabilities' not in params
        if mode == 'fallback' or version == 1:
            if version == 1:
                assert 'clientCapabilities' in params
            result = {'protocolVersion': 1}
        else:
            result = {'protocolVersion': 2, 'info': {'name': 'fixture', 'version': '1'}}
    elif method in ('session/new', 'session/resume'):
        record(method)
        if method == 'session/resume':
            assert params['sessionId'] == session_id
            assert params['replayFrom'] == {'type': 'start'}
            update(session_id, 'subagent_update', sessionId='child', title='Synthetic child')
            update('child', 'agent_message_chunk', messageId='historic',
                   content={'type': 'text', 'text': 'Do not republish history'})
            update(session_id, 'replay_complete')
            if mode != 'missing-child-barrier':
                update('child', 'replay_complete')
                update('child', 'state_update', state='unknown')
            update(session_id, 'state_update', state='idle')
        result = {'sessionId': session_id}
        if version == 2:
            result['availableCommands'] = [
                {'type': 'future', 'name': 'ignored', 'description': 'Ignored'},
                {'type': 'command', 'name': 'test', 'description': 'Fixture command',
                 'input': {'type': 'text', 'hint': 'fixture argument'}},
            ]
            result['configOptions'] = [
                {'configId': 'example', 'name': 'Example', 'type': 'boolean', 'currentValue': False},
            ]
    elif method == 'session/set_config_option':
        record(method, params.get('type'))
        assert params == {'sessionId': session_id, 'configId': 'example',
                          'type': 'boolean', 'value': True}
        result = {'configOptions': []}
    elif method == 'session/prompt':
        key = params.get('idempotencyKey', 'v1')
        record(method, key)
        assert params['sessionId'] == session_id
        if version == 1:
            assert key == 'v1'
            result = {'stopReason': 'end_turn'}
        else:
            assert 1 <= len(key) <= 255
            if mode == 'drop':
                break
            if mode == 'invalid-ack':
                write({'id': req['id'], 'result': {'stopReason': 'end_turn'}})
                continue
            update(session_id, 'state_update', state='idle', stopReason='end_turn')
            if mode != 'pre-ack':
                write({'id': req['id'], 'result': {'messageId': message_id}})
            update(session_id, 'user_message', messageId=message_id,
                   content=[{'type': 'text', 'text': 'Synthetic user'}])
            update('foreign', 'state_update', state='idle', stopReason='end_turn')
            update(session_id, 'state_update', state='running')
            update(session_id, 'agent_message_chunk', messageId='synthetic-assistant',
                   content={'type': 'text', 'text': 'Synthetic reply'})
            if mode == 'interaction':
                update(session_id, 'tool_call_update', toolCallId='same', title='Root tool', status='pending')
                update('foreign', 'tool_call_update', toolCallId='same', title='Foreign tool', status='pending')
                update(session_id, 'subagent_update', sessionId='child', title='Child')
                update('child', 'tool_call_update', toolCallId='same', title='Child tool', status='pending')
                update(session_id, 'state_update', state='running', background=[{'type': 'tool_call', 'toolCallId': 'same'}])
                update(session_id, 'state_update', state='requires_action')
                form = {'mode': 'form', 'message': 'Fixture choices', 'requestedSchema': {
                    'type': 'object', 'properties': {'answer': {'type': 'string', 'enum': ['Yes', 'No']}},
                    'required': ['answer'],
                }}
                write({'id': 'foreign-form', 'method': 'elicitation/create', 'params': {**form, 'sessionId': 'foreign'}})
                write({'id': 'approval', 'method': 'session/request_permission', 'params': {'sessionId': session_id}})
                write({'id': 'owned-form', 'method': 'elicitation/create', 'params': {**form, 'sessionId': session_id}})
                continue
            if mode == 'error':
                update(session_id, 'state_update', state='idle', stopReason='error',
                       error={'code': -32603, 'message': 'Synthetic failure'})
            elif mode == 'targeted':
                update(session_id, 'tool_call_update', toolCallId='owned', title='Cancelable tool',
                       status='in_progress', capabilities={'cancel': {}})
                update(session_id, 'state_update', state='idle', stopReason='end_turn',
                       background=[{'type': 'tool_call', 'toolCallId': 'owned'}])
            elif mode != 'cancel':
                update(session_id, 'state_update', state='idle', stopReason='end_turn')
            if mode != 'pre-ack':
                continue
            result = {'messageId': message_id}
    elif method == 'tool_call/cancel':
        record(method)
        assert params == {'sessionId': session_id, 'toolCallId': 'owned'}
        write({'id': req['id'], 'result': {}})
        update(session_id, 'tool_call_update', toolCallId='owned', status='cancelled')
        update(session_id, 'state_update', state='idle', background=[])
        continue
    elif method == 'session/cancel':
        record(method)
        assert params == {'sessionId': session_id}
        update(session_id, 'state_update', state='idle', stopReason='cancelled')
        continue
    if 'id' in req:
        write({'id': req['id'], 'result': result})
