#!/usr/bin/env bash

CF_STACK_NAME="cognito-api-gateway"

get_account_id() {
  ACCOUNT_ID=$(aws sts get-caller-identity \
      --query 'Account' --output text)
}

get_stack_region() {
  STACK_REGION=$(aws configure get region)
}

get_cognito_users_password() {
  COGNITO_USERS_PASSWORD=$(aws cloudformation describe-stacks \
    --stack-name ${CF_STACK_NAME} \
    --query 'Stacks[0].Parameters[0].ParameterValue' --output text)
}

get_cognito_username_and_password() {
  OUTPUT=($(aws cloudformation describe-stacks \
        --stack-name ${CF_STACK_NAME} \
        --query 'Stacks[0].[Parameters[0:2].ParameterValue]' \
        --output text))

  COGNITO_USERS_PASSWORD="${OUTPUT[0]}"
  COGNITO_USERNAME="${OUTPUT[1]}"
}

get_api_url_cognitouser_cognitouserpass_cognitoclientid() {
  OUTPUT=($(aws cloudformation describe-stacks \
        --stack-name ${CF_STACK_NAME} \
        --query 'Stacks[0].[Parameters[0:2].ParameterValue, Outputs[1].OutputValue, Outputs[0].OutputValue] | []' \
        --output text))

  COGNITO_USERS_PASSWORD="${OUTPUT[0]}"
  COGNITO_USERNAME="${OUTPUT[1]}"
  API_URL="${OUTPUT[2]}"
  COGNITO_CLIENT_ID="${OUTPUT[3]}"
}

get_api_url_v2_cognitouser_cognitouserpass_cognitoclientid() {
  OUTPUT=($(aws cloudformation describe-stacks \
        --stack-name ${CF_STACK_NAME} \
        --query 'Stacks[0].[Parameters[0:2].ParameterValue, Outputs[3].OutputValue, Outputs[0].OutputValue] | []' \
        --output text))

  COGNITO_USERS_PASSWORD="${OUTPUT[0]}"
  COGNITO_USERNAME="${OUTPUT[1]}"
  API_URL_V2="${OUTPUT[2]}"
  COGNITO_CLIENT_ID="${OUTPUT[3]}"
}

get_api_url() {
  API_URL=$(aws cloudformation describe-stacks \
    --stack-name ${CF_STACK_NAME} \
    --query 'Stacks[0].Outputs[1].OutputValue' --output text)
}

get_login_payload_data() {
  DATA=$(cat<<EOF
{
  "AuthParameters" : {
    "USERNAME" : "${COGNITO_USERNAME}",
    "PASSWORD" : "${COGNITO_USERS_PASSWORD}"
  },
  "AuthFlow" : "USER_PASSWORD_AUTH",
  "ClientId" : "${COGNITO_CLIENT_ID}"
}
EOF)
}

get_access_token() {
  get_stack_region

  ACCESS_TOKEN=$(curl -s -X POST --data "${DATA}" \
    -H 'X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth' \
    -H 'Content-Type: application/x-amz-json-1.1' \
    https://cognito-idp."${STACK_REGION}".amazonaws.com/ | cut -d':' -f 3 | cut -d'"' -f 2)
}

create_s3_bucket_for_lambdas() {
  get_account_id
  get_stack_region

  S3_BUCKET_NAME="${CF_STACK_NAME}-${ACCOUNT_ID}-${STACK_REGION}-lambdas"

  if [[ "${STACK_REGION}" == "us-east-1" ]]
  then
    aws s3api create-bucket \
      --bucket "${S3_BUCKET_NAME}" \
      --region "${STACK_REGION}" > /dev/null
  else
    aws s3api create-bucket \
      --bucket "${S3_BUCKET_NAME}" \
      --region "${STACK_REGION}" \
      --create-bucket-configuration LocationConstraint="${STACK_REGION}" > /dev/null
  fi

  aws s3 cp ./cf-lambdas/custom-auth.zip s3://"${S3_BUCKET_NAME}"
  aws s3 cp ./cf-lambdas/pets-api.zip s3://"${S3_BUCKET_NAME}"
}

delete_s3_bucket_for_lambdas() {
  get_account_id
  get_stack_region

  S3_BUCKET_NAME="${CF_STACK_NAME}-${ACCOUNT_ID}-${STACK_REGION}-lambdas"

  aws s3 rm s3://"${S3_BUCKET_NAME}/custom-auth.zip"
  aws s3 rm s3://"${S3_BUCKET_NAME}/pets-api.zip"

  aws s3api delete-bucket \
    --bucket "${S3_BUCKET_NAME}" \
    --region "${STACK_REGION}" > /dev/null
}

check_for_function_exit_code() {
  EXIT_CODE="$1"
  MSG="$2"

  if [[ "$?" == "${EXIT_CODE}" ]]
  then
    echo "${MSG}"
  else
    echo "Error occured. Please verify your configurations and try again."
  fi
}

for var in "$@"
do
  case "$var" in
    cf-create-stack-gen-password)
      COGNITO_USER_PASS=Pa%%word-$(date +%F-%H-%M-%S)
      echo "" && echo "Generated password: ${COGNITO_USER_PASS}"

      COGNITO_USER_PASS="${COGNITO_USER_PASS}" bash ./helper.sh cf-create-stack
      ;;
    cf-create-stack-openssl-gen-password)
      COGNITO_USER_PASS=Pa%%word-$(openssl rand -hex 12)
      echo "" && echo "Generated password: ${COGNITO_USER_PASS}"

      COGNITO_USER_PASS="${COGNITO_USER_PASS}" bash ./helper.sh cf-create-stack
      ;;
    cf-create-stack)
      create_s3_bucket_for_lambdas

    echo "Creating CloudFormation Stack in region ${STACK_REGION}."
      STACK_ID=$(aws cloudformation create-stack \
        --stack-name ${CF_STACK_NAME} \
        --template-body file://infrastructure/stack-no-auth.template \
        --parameters ParameterKey=CognitoUserPassword,ParameterValue=${COGNITO_USER_PASS} \
        --capabilities CAPABILITY_NAMED_IAM \
        --query 'StackId' --output text)

      aws cloudformation wait stack-create-complete \
        --stack-name ${STACK_ID}

      check_for_function_exit_code "$?" "Successfully created CloudFormation stack."
      ;;
    cf-update-stack)
      get_cognito_users_password

      STACK_ID=$(aws cloudformation update-stack \
        --stack-name ${CF_STACK_NAME} \
        --template-body file://infrastructure/stack-with-auth.template \
        --parameters ParameterKey=CognitoUserPassword,ParameterValue=${COGNITO_USERS_PASSWORD} \
        --capabilities CAPABILITY_NAMED_IAM \
        --query 'StackId' --output text)

      aws cloudformation wait stack-update-complete \
        --stack-name ${STACK_ID}

      check_for_function_exit_code "$?" "Successfully updated CloudFormation stack."
      ;;
    cf-delete-stack)
      delete_s3_bucket_for_lambdas

      aws cloudformation delete-stack \
        --stack-name ${CF_STACK_NAME} >> /dev/null

      echo "Deleting CloudFormation stack. If you want to wait for delete complition please run command below."
      echo "bash ./helper.sh cf-delete-stack-completed"
      ;;
    cf-delete-stack-completed)
      aws cloudformation wait stack-delete-complete \
        --stack-name ${CF_STACK_NAME}

      check_for_function_exit_code "$?" "Successfully deleted CloudFormation stack."
      ;;
    open-cognito-ui)
      COGNITO_UI_URL=$(aws cloudformation describe-stacks \
        --stack-name ${CF_STACK_NAME} \
        --query 'Stacks[0].Outputs[2].OutputValue' --output text)

      get_cognito_username_and_password

      echo "Opening Cognito UI. Please use following credentials to login:"
      echo "Username: ${COGNITO_USERNAME}"
      echo "Password: ${COGNITO_USERS_PASSWORD}"

      # for visual effect for user to recognize msg above
      ./helper.sh visual 6

      open "${COGNITO_UI_URL}"
      ;;
    curl-api)
      get_api_url
      curl "${API_URL}"
      echo ""
      ;;
    curl-api-invalid-token)
      get_api_url
      curl -s -H "Authorization: Bearer aGVhZGVy.Y2xhaW1z.c2lnbmF0dXJl" "${API_URL}"
      echo ""
      ;;
    curl-protected-api)
      echo "Getting API URL, Cognito Username, Cognito Users Password and Cognito ClientId..."
      get_api_url_cognitouser_cognitouserpass_cognitoclientid

      get_login_payload_data
      echo "Authenticating to get access_token..."
      get_access_token

      echo "Making api call..."
      curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL}"
      ;;
    curl-protected-api-not-allowed-endpoint)
      echo "Getting API URL, Cognito Username, Cognito Users Password and Cognito ClientId..."
      get_api_url_v2_cognitouser_cognitouserpass_cognitoclientid

      get_login_payload_data
      echo "Authenticating to get access_token..."
      get_access_token

      echo "Making api call..."
      curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL_V2}"
      echo ""
      ;;
    create-s3-bucket)
      create_s3_bucket_for_lambdas
      ;;
    delete-s3-bucket)
      delete_s3_bucket_for_lambdas
      ;;
    package-custom-auth)
      cd ./custom-auth
      mkdir ./package
      # may try with pip3 install --target ./package python-jose==3.2.0 if you have pip3
      pip install --target ./package python-jose==3.2.0
      cd ./package
      zip -r ../custom-auth.zip . > /dev/null
      cd .. && zip -g custom-auth.zip lambda.py
      mv ./custom-auth.zip ../cf-lambdas
      rm -r ./package

      echo "Successfully completed packaging custom-auth."
      ;;
    package-pets-api)
      cd ./pets-api
      zip pets-api.zip lambda.py && mv pets-api.zip ../cf-lambdas

      echo "Successfully completed packaging pets-api."
      ;;
    package-lambda-functions)
      mkdir -p cf-lambdas
      bash ./helper.sh package-custom-auth
      bash ./helper.sh package-pets-api

      echo "Successfully completed packaging files."
      ;;
    visual)
      for ((i=1;i<=${2};i++));
      do
       sleep 0.5 && echo -n "."
      done
      ;;
    *)
      ;;
  esac
done
