import os
import boto3
import json
import time
import urllib.request
from jose import jwk, jwt
from jose.utils import base64url_decode

# envs
TABLE_NAME = os.environ['TABLE_NAME']
AWS_REGION = os.environ['AWS_REGION']
COGNITO_USER_POOL_ID = os.environ['COGNITO_USER_POOL_ID']
COGNITO_APP_CLIENT_ID = os.environ['COGNITO_APP_CLIENT_ID']

keys_url = 'https://cognito-idp.{}.amazonaws.com/{}/.well-known/jwks.json'.format(AWS_REGION, COGNITO_USER_POOL_ID)
# instead of re-downloading the public keys every time
# we download them only on cold start
# https://aws.amazon.com/blogs/compute/container-reuse-in-lambda/
with urllib.request.urlopen(keys_url) as f:
    response = f.read()
keys = json.loads(response.decode('utf-8'))['keys']


def handler(event, context):
    print(event)

    token_data = parse_token_data(event)
    if token_data['valid'] is False:
        return get_deny_policy()

    try:
        claims = validate_token(token_data['token'])
        groups = claims['cognito:groups']

        results = batch_query_wrapper(TABLE_NAME, 'group', groups)
        print(results)

        if len(results) > 0:
            policy = {
                'Version': results[0]['policy']['Version'],
                'Statement': []
            }
            for item in results:
                policy['Statement'] = policy['Statement'] + item['policy']['Statement']

            return get_response_object(policy)

        return get_deny_policy()

    except Exception as e:
        print(e)

    return get_deny_policy()


def get_response_object(policyDocument, principalId='yyyyyyyy', context={}):
    return {
        "principalId": principalId,
        "policyDocument": policyDocument,
        "context": context,
        "usageIdentifierKey": "{api-key}"
    }


def get_deny_policy():
    return {
        "principalId": "yyyyyyyy",
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "execute-api:Invoke",
                    "Effect": "Deny",
                    "Resource": "arn:aws:execute-api:*:*:*/ANY/*"
                }
            ]
        },
        "context": {},
        "usageIdentifierKey": "{api-key}"
    }


def batch_query_wrapper(table, key, values):
    results = []

    dynamodb = boto3.resource('dynamodb', region_name=AWS_REGION)
    values_list = [values[x:x + 25] for x in range(0, len(values), 25)]

    for vlist in values_list:
        response = dynamodb.batch_get_item(RequestItems={table: {'Keys': [{key: val} for val in vlist]}})
        results.extend(response['Responses'][table])

        while response['UnprocessedKeys']:
            response = dynamodb.batch_get_item(RequestItems={table: {'Keys': [{key: val} for val in vlist]}})
            results.extend(response['Response'][table])

    return results


def parse_token_data(event):
    response = {'valid': False}

    if 'Authorization' not in event['headers']:
        return response

    auth_header = event['headers']['Authorization']
    auth_header_list = auth_header.split(' ')

    # deny request of header isn't made out of two strings, or
    # first string isn't equal to "Bearer" (enforcing following standards,
    # but technically could be anything or could be left out completely)
    if len(auth_header_list) != 2 or auth_header_list[0] != 'Bearer':
        return response

    access_token = auth_header_list[1]
    return {
        'valid': True,
        'token': access_token
    }


def validate_token(token):
    # get the kid from the headers prior to verification
    headers = jwt.get_unverified_headers(token)
    kid = headers['kid']

    # search for the kid in the downloaded public keys
    key_index = -1
    for i in range(len(keys)):
        if kid == keys[i]['kid']:
            key_index = i
            break

    if key_index == -1:
        print('Public key not found in jwks.json')
        return False

    # construct the public key
    public_key = jwk.construct(keys[key_index])

    # get the last two sections of the token,
    # message and signature (encoded in base64)
    message, encoded_signature = str(token).rsplit('.', 1)

    # decode the signature
    decoded_signature = base64url_decode(encoded_signature.encode('utf-8'))

    # verify the signature
    if not public_key.verify(message.encode("utf8"), decoded_signature):
        print('Signature verification failed')
        return False

    print('Signature successfully verified')

    # since we passed the verification, we can now safely
    # use the unverified claims
    claims = jwt.get_unverified_claims(token)

    # additionally we can verify the token expiration
    if time.time() > claims['exp']:
        print('Token is expired')
        return False

    # and the Audience  (use claims['client_id'] if verifying an access token)
    if claims['client_id'] != COGNITO_APP_CLIENT_ID:
        print('Token was not issued for this audience')
        return False

    # now we can use the claims
    print(claims)
    return claims
