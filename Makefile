# Oneshell means I can run multiple lines in a recipe in the same shell, so I don't have to
# chain commands together with semicolon
.ONESHELL:

# Set shell
SHELL=/bin/bash

# Conda environment
CONDA_ENV_NAME=django-on-aws
CONDA_CREATE=source $$(conda info --base)/etc/profile.d/conda.sh ; conda env create
CONDA_ACTIVATE=source $$(conda info --base)/etc/profile.d/conda.sh ; conda activate

# CI/CD docker image
DOCKER_USER=gbournique
CICD_IMAGE_REPOSITORY=${DOCKER_USER}/cicd-with-deps
CICD_IMAGE_TAG=$$(cat environment.yml poetry.lock | cksum | cut -c -8)

# Terraform to create ec2 instances
TF_DIR=./deployment/dev/terraform
TF_LOG_PATH=./terraform-crash.log
TF_LOG=TRACE
ANSIBLE_DIR=./deployment/dev/ansible

# Ansible variables to provision ec2 instances with git repository
ANSIBLE_HOST_KEY_CHECKING=False
ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible_vault_pass
ANSIBLE_GIT_REPO_NAME=django-on-aws
ANSIBLE_GIT_BRANCH_NAME=main
ANSIBLE_PYTHON_VERSION=$(shell python -V | awk '{print $$NF}')

# Cloudformation
# Note The ENVIRONMENT environment variable (dev/demo) is used as the subdomain name, eg. demo.mydomain.com
# If set to 'demo', then an RDS database snapshot will be created on stack deletion 
ENVIRONMENT?=demo
STACK_NAME=$(ENVIRONMENT)
S3_BUCKET_NAME_CFN_TEMPLATES=gbournique-sam-artifacts
PROD_DEPLOYMENT_DIR=deployment/prod
CFN_PARENT_TEMPLATE_FILE="${PROD_DEPLOYMENT_DIR}/cloudformation/parent-stack.yaml"
CFN_PACKAGED_TEMPLATE_FILE="${PROD_DEPLOYMENT_DIR}/cloudformation/nested-stacks.yaml"
CFN_PARAMETERS_FILE="${PROD_DEPLOYMENT_DIR}/cloudformation/cfn-parameters.json"
TAG_NAME="Guillaume Bournique"
TAG_EMAIL="gbournique.dev1@gmail.com"
TAG_MODIFIED_DATE="$$(date +%F_%T)"

# Deployment
WEBAPP_IMAGE_REPOSITORY=${DOCKER_USER}/django-on-aws
# Checksum of the application and dependencies files
# to check if identical docker image already exists in docker repository
CKSUM=$$(cat Dockerfile environment.yml poetry.lock $$(find ./app -type f -not -name "*.pyc" -not -name "*.log") | cksum | cut -c -8)
WEBAPP_IMAGE_TAG=$$(shell poetry version | awk '{print $$NF}')-$(CKSUM)
DEBUG=False
CODEDEPLOY_APP_DIR=${PROD_DEPLOYMENT_DIR}/codedeploy-app

# Database
RDS_POSTGRES_HOST=$$(echo "$$($(call get_stack_output, PostgresRdsEndpoint))")

# Load testing
WEBSERVER_URL=https://${STACK_NAME}.bournique.fr
USERS=100
SPAWN_RATE=50
RUN_TIME=1mn

include utils/helpers.mk

### Environment and pre-commit hooks ###
.PHONY: env env-update pre-commit
env:
	@ ${INFO} "Creating ${CONDA_ENV_NAME} conda environment and poetry dependencies"
	@ $(CONDA_CREATE) -f environment.yml -n $(CONDA_ENV_NAME)
	@ ($(CONDA_ACTIVATE) $(CONDA_ENV_NAME); poetry install)
	@ ${SUCCESS} "${CONDA_ENV_NAME} conda environment has been created and dependencies installed with Poetry."
	@ ${MESSAGE} "Please activate the environment with: conda activate ${CONDA_ENV_NAME}"

env-update:
	@ ${INFO} "Updating ${CONDA_ENV_NAME} conda environment and poetry dependencies"
	@ conda env update -f environment.yml -n $(CONDA_ENV_NAME)
	@ ($(CONDA_ACTIVATE) $(CONDA_ENV_NAME); poetry update)
	@ ${SUCCESS} "${CONDA_ENV_NAME} conda environment and poetry dependencies have been updated!"

pre-commit:
	@ pre-commit install -t pre-commit -t commit-msg
	@ ${SUCCESS} "pre-commit set up"


### Development ###
.PHONY: runserver tests open-cov-report

runserver:
	python app/manage.py collectstatic --no-input -v 0
	python app/manage.py makemigrations main
	python app/manage.py migrate --run-syncdb
	python app/manage.py runserver 0.0.0.0:8080

### Containerised testing and CI/CD ###
.PHONY: build-image-cicd-if-not-exists build-image-webapp-if-not-exists db-up lint tests healthcheck db-down

# global-network so that db containers and webapp container can communicate
run_docker_ci = { \
	docker network create global-network 2>/dev/null || true; \
	docker run \
		-it --rm --name "$(1)" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $$(pwd):/root/cicd/ \
		--network global-network \
		-e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} \
		-e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
		-e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
		${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} bash -c "$(2)"; \
}

build-image-cicd-if-not-exists:
	@ export DOCKER_CLI_EXPERIMENTAL=enabled
	@ if docker manifest inspect ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG}; then \
		${INFO} "Docker image ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} already exists on Dockerhub! Not building deps."; \
		docker pull ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG}; \
	  else \
	  	${INFO} "Docker image ${CICD_IMAGE_REPOSITORY}:$(CICD_IMAGE_TAG) does not exist on Dockerhub! Building and publishing."; \
		docker build -t ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} -f .circleci/cicd.Dockerfile . ; \
		echo "${DOCKER_PASSWORD}" | docker login --username "${DOCKER_USER}" --password-stdin 2>&1; \
		docker push ${CICD_IMAGE_REPOSITORY}:$(CICD_IMAGE_TAG); \
		docker tag ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} ${CICD_IMAGE_REPOSITORY}:latest; \
		docker push ${CICD_IMAGE_REPOSITORY}:latest; \
	  fi

build-image-webapp-if-not-exists:
	$(call \
		run_docker_ci,ci-build-image-webapp, \
		if docker manifest inspect ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} > /dev/null 2>&1; then \
			docker pull ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG}; \
	  	else \
			rm -rf dist; \
			poetry build; \
			docker build -t ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} . ; \
	  	fi \
	)

db-up:
	@ $(call \
		run_docker_ci,ci-rundb, \
		docker-compose up -d || true \
	)

lint:
	@ $(call \
		run_docker_ci,ci-lint, \
		pre-commit run --all-files --show-diff-on-failure \
	)

tests: db-up
	@ $(call \
		run_docker_ci,ci-unit-tests, \
		pytest app -x; coverage-badge -o .github/coverage.svg -f \
	)
	@ ${INFO} "Run open htmlcov/index.html to open coverage results"

healthcheck: db-up
	@ $(call \
		run_docker_ci,ci-webapp-healthcheck, \
		docker rm --force $$(docker ps --filter "name=webapp" -qa) 2>/dev/null || true; \
		docker run \
			-d --name webapp -p 8080:8080 --restart=no \
			--network global-network \
			--env DEBUG=True \
			--env POSTGRES_HOST=postgres \
			--env POSTGRES_PASSWORD=postgres \
			--env REDIS_ENDPOINT=redis:6379 \
			--env SNS_TOPIC_ARN= \
			${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} || true; \
		./utils/healthcheck.sh webapp; \
	)

db-down:
	@ $(call \
		run_docker_ci,ci-down, \
		docker rm --force $$(docker ps --filter "name=webapp" -qa) 2>/dev/null || true; \
		docker-compose down --remove-orphans 2>/dev/null || true \
	)

publish-images:
	@ $(call \
		run_docker_ci,publish-images, \
		echo "${DOCKER_PASSWORD}" | docker login --username "${DOCKER_USER}" --password-stdin 2>&1; \
		docker push ${WEBAPP_IMAGE_REPOSITORY}:$(WEBAPP_IMAGE_TAG); \
		docker tag ${WEBAPP_IMAGE_REPOSITORY}:$(WEBAPP_IMAGE_TAG) ${WEBAPP_IMAGE_REPOSITORY}:latest; \
		docker push ${WEBAPP_IMAGE_REPOSITORY}:latest; \
	)

put-image-name-to-ssm:
	@ ${INFO} "Update docker image name in aws ssm parameter store: (IMAGE=${WEBAPP_IMAGE_REPOSITORY}:latest; DEBUG=${DEBUG})"
	@ $(call \
		run_docker_ci,put-image-name-to-ssm, \
		aws ssm put-parameter \
			--name "/CODEDEPLOY/DOCKER_IMAGE_NAME_DEMO" \
			--type "String" \
			--value "${WEBAPP_IMAGE_REPOSITORY}:latest" \
			--overwrite >/dev/null; \
		aws ssm put-parameter \
			--name "/CODEDEPLOY/DEBUG_DEMO" \
			--type "String" \
			--value "${DEBUG}" \
			--overwrite >/dev/null \
	)

### Development and Testing on Remote EC2 with Terraform+Ansible ###
.PHONY: create-and-deploy-to-ec2 destroy-ec2

create-instances:
	cd "${TF_DIR}"
	TF_LOG_PATH=$(TF_LOG_PATH)
	TF_LOG=$(TF_LOG)
	terraform init
	terraform fmt -recursive
	terraform validate
	terraform plan -out=./.terraform/terraform_plan
	terraform apply ./.terraform/terraform_plan

provision-instances:
	@ ${INFO} "Git clone repository and start dockerised application to created instances with Ansible"
	export ANSIBLE_HOST_KEY_CHECKING=$(ANSIBLE_HOST_KEY_CHECKING)
	export ANSIBLE_HOST_KEY_CHECKING=$(ANSIBLE_HOST_KEY_CHECKING)
	export ANSIBLE_VAULT_PASSWORD_FILE=$(ANSIBLE_VAULT_PASSWORD_FILE)
	export ANSIBLE_GIT_REPO_NAME=$(ANSIBLE_GIT_REPO_NAME)
	export ANSIBLE_GIT_BRANCH_NAME=$(ANSIBLE_GIT_BRANCH_NAME)
	export ANSIBLE_PYTHON_VERSION=$(ANSIBLE_PYTHON_VERSION)
	export DOCKER_USER=$(DOCKER_USER)
	ansible-playbook -i "${ANSIBLE_DIR}/inventories" "${ANSIBLE_DIR}/staging.yaml" -vv --timeout 60

show-urls:
	@ ${INFO} "Public URL(s) where the app is running"
	@ cd "${TF_DIR}"; terraform output public_ips

deploy-to-dev-instances:
	@ $(MAKE) create-instances
	@ $(MAKE) provision-instances
	@ $(MAKE) show-urls
	@ ${INFO} "Run make destroy-instances to clean up"

destroy-instances:
	@ ${INFO} "Destroying all infrastructure created by Terraform"
	@ cd "${TF_DIR}"; terraform destroy --auto-approve


### Infrastructure ###
.PHONY: cfn-validate cfn-create cfn-update cfn-delete

cfn-package:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Packaging nested CloudFormation templates into ${CFN_PACKAGED_TEMPLATE_FILE}"
	@ aws cloudformation package \
		--template-file ${CFN_PARENT_TEMPLATE_FILE} \
		--output-template ${CFN_PACKAGED_TEMPLATE_FILE} \
		--s3-bucket ${S3_BUCKET_NAME_CFN_TEMPLATES}

cfn-validate: cfn-package
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Validating CloudFormation template ${CFN_PACKAGED_TEMPLATE_FILE}"
	@ aws cloudformation validate-template --template-body file://"${CFN_PACKAGED_TEMPLATE_FILE}" > /dev/null

cfn-create: cfn-validate
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Creating stack ${STACK_NAME}..."
	@ aws cloudformation create-stack \
		--stack-name=${STACK_NAME} \
		--template-body=file://"${CFN_PACKAGED_TEMPLATE_FILE}" \
		--parameters ParameterKey=ASGCPUTargetValue,ParameterValue=60 \
					ParameterKey=ASGDesiredCapacity,ParameterValue=2 \
					ParameterKey=CloudFrontExistingCertArn,ParameterValue=arn:aws:acm:us-east-1:164045463835:certificate/26654aed-53fe-4033-9866-9b072ad88ed8 \
					ParameterKey=EC2LatestLinuxAmiId,ParameterValue=/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
					ParameterKey=EC2InstanceType,ParameterValue=t2.micro \
					ParameterKey=EC2VolumeSize,ParameterValue=8 \
					ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
					ParameterKey=R53HostedZoneName,ParameterValue=bournique.fr \
					ParameterKey=SSMParamSlackWebhookUrl,ParameterValue=/SLACK/INCOMING_WEBHOOK_URL \
					ParameterKey=SSMParamNameRdsPostgresPassword,ParameterValue=/RDS/POSTGRES_PASSWORD/SECURE \
					ParameterKey=SubnetListStr,ParameterValue=\"subnet-103a1a79\,subnet-28219264\" \
					ParameterKey=VpcId,ParameterValue=vpc-e82c7280 \
		--tags "Key"="Name","Value"=\"${TAG_NAME}\" \
			   "Key"="Modified_Date","Value"="${TAG_MODIFIED_DATE}" \
			   "Key"="Email","Value"="${TAG_EMAIL}" \
		--capabilities=CAPABILITY_NAMED_IAM
	@ echo "$$($(call wait_for_stack_creation_status))"

cfn-update: cfn-validate
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Updating stack ${STACK_NAME}..."
	@ aws cloudformation update-stack \
		--stack-name=${STACK_NAME} \
		--template-body=file://"${CFN_PACKAGED_TEMPLATE_FILE}" \
		--parameters ParameterKey=ASGCPUTargetValue,ParameterValue=60 \
					ParameterKey=ASGDesiredCapacity,ParameterValue=2 \
					ParameterKey=CloudFrontExistingCertArn,ParameterValue=arn:aws:acm:us-east-1:164045463835:certificate/26654aed-53fe-4033-9866-9b072ad88ed8 \
					ParameterKey=EC2LatestLinuxAmiId,ParameterValue=/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
					ParameterKey=EC2InstanceType,ParameterValue=t2.micro \
					ParameterKey=EC2VolumeSize,ParameterValue=8 \
					ParameterKey=Environment,ParameterValue=${ENVIRONMENT} \
					ParameterKey=R53HostedZoneName,ParameterValue=bournique.fr \
					ParameterKey=SSMParamSlackWebhookUrl,ParameterValue=/SLACK/INCOMING_WEBHOOK_URL \
					ParameterKey=SSMParamNameRdsPostgresPassword,ParameterValue=/RDS/POSTGRES_PASSWORD/SECURE \
					ParameterKey=SubnetListStr,ParameterValue=\"subnet-103a1a79\,subnet-28219264\" \
					ParameterKey=VpcId,ParameterValue=vpc-e82c7280 \
		--tags "Key"="Name","Value"=\"${TAG_NAME}\" \
			   "Key"="Modified_Date","Value"="${TAG_MODIFIED_DATE}" \
			   "Key"="Email","Value"="${TAG_EMAIL}" \
		--capabilities=CAPABILITY_NAMED_IAM
	@ echo "$$($(call wait_for_stack_update_status))"

cfn-delete:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Deleting stack ${STACK_NAME}..."
	@ aws cloudformation delete-stack --stack-name="${STACK_NAME}"
	@ echo "$$($(call wait_for_stack_delete_status))"

cfn-delete-async:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Deleting stack ${STACK_NAME}..."
	@ aws cloudformation delete-stack --stack-name="${STACK_NAME}"

### Deployment ###
.PHONY: deploy deploy-push deploy-create deploy-get-status

deploy: put-image-name-to-ssm deploy-push deploy-create deploy-get-status

deploy-push:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Push code to S3 and create a CodeDeploy application revision"
	@ aws deploy push \
		--application-name "$$($(call get_stack_output, CodeDeployApplicationName))" \
		--s3-location "s3://$$($(call get_stack_output, CodeDeployS3BucketName))/$$($(call codedeploy_app_name)).zip" \
		--source "${CODEDEPLOY_APP_DIR}" \
		--ignore-hidden-files

deploy-create:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Create deployment from the latest CodeDeploy application revision"
	@ aws deploy create-deployment \
		--application-name "$$($(call get_stack_output, CodeDeployApplicationName))" \
		--deployment-group-name "$$($(call get_stack_output, CodeDeployDeploymentGroupName))" \
		--s3-location "$$($(call codedeploy_s3_artifact))" \
		--description "Created by make deploy-create-deployment" \
		--file-exists-behavior OVERWRITE

deploy-get-status:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Check deployment status..."
	@ echo "$$($(call wait_for_codedeploy_deployment_status))"


# Load Testing
load-testing:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Load testing ${WEBSERVER_URL} by spawning ${USERS} users (${SPAWN_RATE}/s) for ${RUN_TIME} minutes."
	@ locust -f utils/locustfile.py \
		--host ${WEBSERVER_URL} \
		--headless --users ${USERS} --spawn-rate ${SPAWN_RATE} --run-time ${RUN_TIME} --only-summary

load-testing-ui:
	@ $(CONDA_ACTIVATE) $(CONDA_ENV_NAME)
	@ ${INFO} "Starting load testing UI"
	@ locust -f utils/locustfile.py --host ${WEBSERVER_URL}