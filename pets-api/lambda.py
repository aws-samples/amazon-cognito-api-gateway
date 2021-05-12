import json

pets = [
    {
        "id": 1,
        "name": "Birds"
    },
    {
        "id": 2,
        "name": "Cats"
    },
    {
        "id": 3,
        "name": "Dogs"
    },
    {
        "id": 4,
        "name": "Fish"
    }
]


def handler(event, context):
    print(event)

    try:
        path = event['path']
        http_method = event['httpMethod']

        if path == '/petstore/v1/pets' and http_method == 'GET':
            return response_handler({'pets': pets}, 200)
        elif '/petstore/v1/pets/' in path and http_method == 'GET':
            pet_id = path.split('/petstore/v1/pets/')[1]
            for pet in pets:
                if pet['id'] == int(pet_id):
                    return response_handler(pet, 200)
        elif path == '/petstore/v2/pets' and http_method == 'GET':
            return response_handler({'pets': pets}, 200)
        elif path == '/petstore/v2/status':
            return response_handler({'status': 'ok'}, 200)
        else:
            return response_handler({}, 404)

    except Exception as e:
        print(e)
        return response_handler({'msg': 'Internal Server Error'}, 500)


def response_handler(payload, status_code):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json"
        },
        "body": json.dumps(payload),
        "isBase64Encoded": False
    }
