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

def communication():
    parent_sends = mode.endswith('outgoing')
    sender, recipient = (session_id, 'child') if parent_sends else ('child', session_id)
    parent_ref = 'parent-copy'
    child_ref = 'child-copy'
    source_ref, target_ref = (parent_ref, child_ref) if parent_sends else (child_ref, parent_ref)
    content = {'type': 'text', 'text': 'Synthetic agent handoff'}
    # The child observation comes first, with its cross-reference arriving
    # after content. The root observation is the same communication.
    update('child', 'session_message_chunk', messageId=child_ref, content=content)
    update('child', 'session_message', messageId=child_ref, senderSessionId=sender,
           recipientSessionId=recipient, **({'senderMessageId': source_ref} if parent_sends else {'recipientMessageId': target_ref}))
    update(session_id, 'session_message', messageId=parent_ref, senderSessionId=sender,
           recipientSessionId=recipient, content=[content],
           **({'recipientMessageId': target_ref} if parent_sends else {'senderMessageId': source_ref}))

for line in sys.stdin:
    req = json.loads(line)
    if 'method' not in req:
        record('client-response', req['id'], json.dumps(req['result'], sort_keys=True))
        if mode.startswith('child-activity-') and req['id'] == 'approval':
            assert req['result'] == ({'action': 'decline'} if mode.endswith('elicitation') else {'outcome': {'outcome': 'cancelled'}})
            update('child', 'state_update', state='idle')
            update(session_id, 'state_update', state='idle', stopReason='end_turn')
        if req['id'] == 'owned-form':
            update(session_id, 'state_update', state='idle', stopReason='end_turn')
            update(session_id, 'state_update', state='idle', background=[])
        continue
    method = req['method']
    params = req.get('params', {})
    result = {}
    if mode.startswith('communication-'):
        record('wire', method, 'parent' if params.get('sessionId') == session_id else 'other')
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
            if mode.startswith('communication-'):
                communication()
            update(session_id, 'replay_complete')
            if mode != 'missing-child-barrier':
                update('child', 'replay_complete')
                update('child', 'state_update', state='unknown')
            if mode.startswith('retry-'):
                update(session_id, 'state_update', state='idle', stopReason='refusal',
                       background=[{'type': 'tool_call', 'toolCallId': 'retry-background'}])
            else:
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
            if mode == 'recovery':
                update(session_id, 'state_update', state='running', _meta={'graff/networkRecovery': {'phase': 'waiting', 'cause': 'stream_dropped', 'attempt': 2, 'retryInMs': 1200}})
            result = {'stopReason': 'end_turn'}
        else:
            assert 1 <= len(key) <= 255
            if mode.startswith('retry-'):
                assert key.startswith('harness:')
                # A newer message and terminal do not belong to the retry of A.
                update(session_id, 'user_message', messageId='newer-b', content=[])
                update(session_id, 'state_update', state='idle', stopReason='refusal')
                result = {'messageId': 'older-a'}
                reason = mode.removeprefix('retry-')
                if reason != 'live':
                    outcome = {'stopReason': reason}
                    if reason == 'error':
                        outcome['error'] = {'code': -32603, 'message': 'Synthetic saved error'}
                    result['_meta'] = {'graff/turnOutcome': outcome}
                write({'id': req['id'], 'result': result})
                update(session_id, 'user_message', messageId='older-a', content=[])
                update(session_id, 'state_update', state='idle', stopReason='end_turn' if reason == 'live' else 'refusal')
                update(session_id, 'state_update', state='idle', background=[])
                continue
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
            if mode.startswith('communication-'):
                update(session_id, 'subagent_update', sessionId='child', title='Synthetic child')
                communication()
                update('child', 'agent_message', messageId='child-reply', content=[{'type': 'text', 'text': 'Synthetic child reply'}])
            if mode == 'recovery':
                update(session_id, 'state_update', state='running', _meta={'graff/networkRecovery': {'phase': 'waiting', 'cause': 'stream_dropped', 'attempt': 2, 'retryInMs': 1200}})
                update(session_id, 'state_update', state='running')
                update('foreign', 'state_update', state='running', _meta={'graff/networkRecovery': {'phase': 'waiting', 'cause': 'connection_lost', 'attempt': 99, 'retryInMs': 1}})
            if mode.startswith('child-activity-'):
                update(session_id, 'subagent_update', sessionId='child', title='Synthetic child')
                activity = {'kind': 'permission', 'requestId': 'approval', 'toolCallId': 'tool'}
                request = {'id': 'approval', 'method': 'session/request_permission', 'params': {'sessionId': 'child', 'subject': {'type': 'tool_call', 'toolCall': {'toolCallId': 'tool'}}}}
                update(session_id, 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                if mode.endswith('elicitation'):
                    activity['kind'] = 'elicitation'
                    request['method'] = 'elicitation/create'
                    request['params'] = {'sessionId': 'child', 'toolCallId': 'tool', 'mode': 'form', 'message': 'Synthetic question', 'requestedSchema': {'type': 'object', 'properties': {}}}
                if mode.endswith('owned-stale'):
                    update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                    update('child', 'state_update', state='running')
                    write(request)
                    continue
                if mode.endswith('mismatch'):
                    if mode.endswith('id-mismatch'):
                        activity['requestId'] = 7
                    else:
                        activity['toolCallId'] = '' if mode.endswith('empty-tool-mismatch') else 'other'
                    update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                    write(request)
                    continue
                if mode.endswith('null-clear'):
                    write(request)
                    update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': None})
                    update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                    continue
                if mode.endswith('stale'):
                    update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                    update('child', 'state_update', state='running')
                    request['params']['sessionId'] = 'foreign'
                    write(request)
                    continue
                if mode.endswith('request-first'):
                    write(request)
                update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                if not mode.endswith('request-first'):
                    write(request)
                update('child', 'state_update', state='requires_action', _meta={'graff/childActivity': activity})
                continue
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
