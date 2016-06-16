# Continuous Deployment w/Docker, AWS, and Ansible

You've built some docker images and made something locally. Now it's
time to go to production--and you're stuck. This is not uncommon. The
docker for development environments story is well developed. The
community is still writing the production story. This tutorial will
take from a greenfield web project to applicatoin running in
production. The structure looks like:

1. Build and push docker images with `make`
1. Connect that Semaphore CI
1. Pushing image to [AWS ECR][ecr]
1. Bootstrapping a docker [AWS ElasticBeanstalk][eb] application with
	 [AWS Cloudformation][cf].
1. Coordinate infrasturcture & application deployment with [ansible][]

You may be thinking, "hey, this seems like a lot of tools?" You're
onto something. There are multiple moving parts. That's what it
usually takes to get code into production--especially with docker.
Let's take a moment to examine other possible solutions and tools
before jumping in.

## Docker in Production

This area is so hot right now. There is a _polethera_ of ways to
deploy docker containers to production. They roughly fall into three
categories:

1. Scheduling Clusters
	* Mesos, Kubernetes, EC2, Docker Universal Control Plane, and
		others. These systems create a resource pool from a varying number
		of machines. Users can create tasks/jobs (naming varies from
		system to system) and the cluster will schedule it to run. Some
		are docker specific other are not. Generally these things are
		meant for high scale environments and don't make sense for a small
		number of containers.
2. Hosted PaaS
	* Docker Cloud, Heroku, ElasticBeanstalk. These systems abstract the
		cluster and scaling from the end user. Users tell the system how
		to run the application through some confg file. Then the system
		takes care of the rest. These sytsems usually have a low barrier
		to entry, integrate with other services, and are a bit pricey
		compared to other offerings.
3. Self Managed
	* IaaS (AWS, DigitalOcean, SoftLayer) or bare metal. This category
		offers the most flexibility with the most upfront work and
		required technical knowledge. Useful for teams deploying internal
		facing applications or with the time/knowledge to manage
		infrastructure and production operations.

Most teams opt for a combination of option one & three. They may use
AWS to provision a Mesos cluster where developers can deploy their
things to.  Small groups and individuals are best suited for option
two because knowledge, time, and resource constraints. This tutorial
assumes option two. Why ElasticBeanstalk?

## Our Toolchain

ElasticBeanstalk is AWS's PaaS offering. It can run docker, php, ruby,
java, python, go, and probably a few other things. It supports web
applications and cron style worker system. ElasticBeanstalk has an
interesting value proposition. First, it's AWS. Thus anyone teams
already using AWS can integrate it into their public or internal
infrastructure. Second, it's autocaling and generally supports the
most popular platforms in the industry with little effort. Third, it's
easy enough to deploy a single docker container too. Provide the
config file and AWS will sort the rest out. Also it gives the tutorial
a reason to provision infrastructure.

Production infrastructure has to come from somwhere. AWS is the
default choice for advanced use cases. Other cloud providers are
playing catch up here. CloudFormation is the natural choice to
provision all the AWS resources. It's first partner and will generally
have most full featured support compared to tools like [Terraform][].
So how can we pull this whole thing together? [Ansible][] is the
perfect tool in my experience--especially with the built in
cloudformation module. Ansible is easy to learn and just (or more
powerful) for certain use cases then Chef/Puppet. I specifically like
Ansible because it's a mix of configuration management and general
DevOps style automation. Ansible allows us to deploy the
infrastructure, coordinate local calls to build code, and finally make
external calls to trigger new deploys. This may sound complex, but if
I do my job, you'll feel like a pro by the end.

## Step 1: Build & Test a Docker Image

I'll use a dead simple Ruby web application built with [Sinatra][].
The langauge or framework is not specifically relevant for this
tutorial. This is just to demonstrate building and testing a docker
image. I could use a prexisiting "hello world" type image, but that
would be a cop out. This is a greenfield to production tutorial!

The `Makefile` follows my own best pratices for working with [Ruby and
Docker][ruby-docker-tdd]. The tl;dr here is:

* `Gemfile` lists all the application dependencies
* `make Gemfile.lock` uses docker to produce the required dependency
	manifest file
* `make build` Uses the application dependencies to produce a docker
	image on top of the official [ruby image][].
* `make test` Runs the tests included in the docker image
* `src/` contains relevant ruby source files
* `test/` contains the test files

Here are the snippets from the relevant files. The [complete source][]
is available as well. First the `Dockerfile`.

	FROM ruby:2.3

	ENV LC_ALL C.UTF-8

	RUN mkdir -p /app/vendor
	WORKDIR /app
	ENV PATH /app/bin:$PATH

	COPY Gemfile Gemfile.lock /app/
	COPY vendor/cache /app/vendor/cache
	RUN bundle install --local -j $(nproc)

	COPY . /app/

	EXPOSE 80

	CMD [ "bundle", "exec", "rackup", "-o", "0.0.0.0", "-p", "80", "src/config.ru" ]

Now for the `Makefile`

	RUBY_IMAGE:=$(shell head -n 1 Dockerfile | cut -d ' ' -f 2)
	IMAGE:=ahawkins/semaphore-cd
	DOCKER:=tmp/docker

	Gemfile.lock: Gemfile
		docker run --rm -v $(CURDIR):/data -w /data $(RUBY_IMAGE) \
			bundle package --all

	$(DOCKER): Gemfile.lock
		docker build -t $(IMAGE) .
		mkdir -p $(@D)
		touch $@

	.PHONY: build
	build: $(DOCKER)

	.PHONY: test-image
	test-image: $(DOCKER)
		docker run --rm $(IMAGE) \
			ruby $(addprefix -r./,$(wildcard test/*_test.rb)) -e 'exit'

	.PHONY: test-ci
	test-ci: test-image test-cloudformation

	.PHONY: clean
	clean:
		rm -rf $(DOCKER)

Run (after cloning the [source][])

	make clean test-ci

Then you should have a full functioning web server that says "hello
world." Don't believe me? Run `docker run --rm ahawkins/semaphore-cd`
and see if it starts. Time to take the next step and get this running
on CI.

## Step 2: Connecting CI

You guessed it, we'll use Semaphore CI. This is a straight forward
process. Push code to Github and configure in Semaphore CI. We'll two
pipeline steps for now.

1. `make clean`
2. `make test-ci`

Now you should have a green build on CI. Step 3 is pushing this image
somewhere our infrastructure can use.

## Step 3: Pushing the Image

Amazon provides the Elastic Container Registry service where we can
push docker images too. AWS creates a default registry for every AWS
accounts. Luckily for us, Semaphore also provides transparent
integration with ECR. ECR does not allow you push images immediately
however. You must first create the repository where the docker images
live. Now is is a good time to also consider any pre-reqs for the
ElasticBeanstalk application. ElasticBeanstalk requires an S3 bucket
to read, what they call, "Application Versions" from. You can think of
these as "release". Right now we need two things from AWS:

1. A repository in our registry to push image to
1. An S3 bucket to push source code to

Enter Ansible and CloudFormation! We'll use CloudFormation to create
the previously mentioned resources. Ansible allows us to deploy the
cloudformation stack. This is powerful because Ansible automatically
creates or updates the CloudFormation stacks. Whoa! Continous
infrastructure deployment. I'll start by providing the CloudFormation
template but I won't go completely in-depth. Plenty of other resources
are better for that.

CloudFormation templates are JSON documents. CloudFormation reads the
template, builds a dependency graph, then creates or updates
everything accordingly.

	{
		"AWSTemplateFormatVersion": "2010-09-09",
		"Description": "Pre-reqs for Hello World app",
		"Parameters": {
			"BucketName": {
				"Type": "String",
				"Description": "S3 Bucket name"
			},
			"RepositoryName": {
				"Type": "String",
				"Description": "ECR Repository name"
			}
		},
		"Resources": {
			"Bucket": {
				"Type": "AWS::S3::Bucket",
				"Properties": {
					"BucketName": { "Fn::Join": [ "-", [
						{ "Ref": "BucketName" },
						{ "Ref": "AWS::Region" }
					]]}
				}
			},
			"Repository": {
				"Type": "AWS::ECR::Repository",
				"Properties": {
					"RepositoryName": { "Ref": "RepositoryName" }
				}
			}
		},
		"Outputs": {
			"S3Bucket": {
				"Description": "Full S3 Bucket name",
				"Value": { "Ref": "Bucket" }
			},
			"Repository": {
				"Description": "ECR Repo",
				"Value": { "Fn::Join": [ "/", [
					{
						"Fn::Join": [ ".", [
							{ "Ref": "AWS::AccountId" },
							"dkr",
							"ecr",
							{ "Ref": "AWS::Region" },
							"amazonaws.com"
						]]
					},
					{ "Ref": "Repository" }
				]]}
			}
		}
	}

I do want to call out a few things specifically. First there are two
input parameters and two output parameters. ElasticBeanstalk requires
a bucket in a specific region. The templates take the bucket parameter
and appends the region to it. Second, it outputs the complete ECR
registry url. You must know your AWS account ID to use ECR. How many
of you know that off the top of your head? CloudFormation does. We can
use that value to output the full registry endpoint. The value can be
used progrmatically from within Ansible. Time to move onto the Ansible
playbook.

Ansible models things with Playbooks. Playbooks contain tasks. Tasks
use modules to do whatever is required. Playbooks are YML files. We'll
build up the deploy plabook as we go. The first step is to deploy the
previously mentioned CloudFormation stack. The next step is to use the
outputs to push the image to our registry.

	---
	- hosts: localhost
		connection: local
		gather_facts: False
		vars:
			aws_region: eu-west-1
			app_name: "semaphore-cd"
			prereq_stack_name: "{{ app_name }}-prereqs"
			bucket_name: "{{ app_name }}-releases"
		tasks:
			- name: Provision Pre-req stack
				cloudformation:
					state: present
					stack_name: "{{ prereq_stack_name }}"
					region: "{{ aws_region }}"
					disable_rollback: true
					template: "cloudformation/prereqs.json"
					template_parameters:
						BucketName: "{{ bucket_name }}"
						RepositoryName: "{{ app_name }}"
				register: prereqs

			- name: Generate artifact hash
				command: "./script/release-tag"
				changed_when: False
				register: artifact_hash

			- name: Push Image to ECR
				command: "make push UPSTREAM={{ prereqs.stack_outputs.Repository }}:{{ artifact_hash.stdout }}"
				changed_when: False

The first task uses the cloudformation module to create or update the
stack. Second a local script is called to generate a docker image tag.
The script uses `git` to get the current SHA. Finally is uses a (yet
defined) `make` target to push the image to the registry. The new
`make push` target looks like this:

	.PHONY: push
	push:
		docker tag $(IMAGE) $(UPSTREAM)
		docker push $(UPSTREAM)

Ansible provides the `UPSTREAM` variable on the command line. We can
also update our test suite to verify our CloudFormation template.
Here's the relevant snippet.

	.PHONY: test-cloudformation
	test-cloudformation:
		aws --region eu-west-1 cloudformation \
			validate-template --template-body file://cloudformation/prereqs.json

	.PHONY: test-image
	test-image: $(DOCKER)
		docker run --rm $(IMAGE) \
			ruby $(addprefix -r./,$(wildcard test/*_test.rb)) -e 'exit'

	.PHONY: test-ci
	test-ci: test-image test-cloudformation

Now it's time to write the whole thing up on Semaphore! There's a few
things to do there.

1. First set the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
	 environment variables so CI can talk to AWS
1. Use those access keys to configure the Semaphore CI ECR addon to
	 authorize CI to push docker images
1. Install `ansible` as part of the CI run.

Get your access keys and run through the bits in your projects
settings. Then your build steps should be:

1. `sudo pip install ansible`
1. `make clean`
1. `make test-ci`
1. `ansible-playbook deploy.yml`

Finally push your code and you should see the deploy playbook push the
application to the upstream registry.

## Step 4: Deploy Image to ElasticBeanstalk

You've made it to the final level. It's time to put this code into
production. This involves a few moving pieces.

1. Creating an "Application Version" containing the config required to
	 run our container
1. Uploading that file to S3
1. Creating a Docker ElasticBeanstalk Application authorized to pull
	 images from the docker registry (a.k.a. deploying the
	 cloudformation stack with all input parameters).

Let's work backwards from the CloudFormation template

	{
		"AWSTemplateFormatVersion": "2010-09-09",
		"Parameters": {
			"S3Bucket": {
				"Type": "String",
				"Description": "S3 Bucket for clojure collector WAR file"
			},
			"S3ZipKey": {
				"Type": "String",
				"Description": "Path to zip file"
			},
			"RackEnv": {
				"Type": "String",
				"Description": "Value for RACK_ENV and name of this environment"
			},
			"HealthCheckPath": {
				"Type": "String",
				"Description": "Path for container health check"
			}
		},
		"Description": "Hello World EB application & IAM policies",
		"Resources": {
			"ElasticBeanstalkProfile": {
				"Type": "AWS::IAM::InstanceProfile",
				"Properties": {
					"Path": "/hello-world/",
					"Roles": [
						{ "Ref": "ElasticBeanstalkRole" }
					]
				}
			},
			"ElasticBeanstalkRole": {
				"Type": "AWS::IAM::Role",
				"Properties": {
					"Path": "/hello-world/",
					"ManagedPolicyArns": [
						"arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier",
						"arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
					],
					"AssumeRolePolicyDocument": {
						"Version" : "2012-10-17",
						"Statement": [{
							"Effect": "Allow",
							"Principal": {
								"Service": [ "ec2.amazonaws.com" ]
							},
							"Action": [ "sts:AssumeRole" ]
						}]
					},
					"Policies": [ ]
				}
			},
			"ElasticBeanstalkApplication": {
				"Type": "AWS::ElasticBeanstalk::Application",
				"Properties": {
					"Description": "semaphore-cd-hello"
				}
			},
			"ElasticBeanstalkVersion": {
				"Type": "AWS::ElasticBeanstalk::ApplicationVersion",
				"Properties": {
					"ApplicationName": { "Ref": "ElasticBeanstalkApplication" },
					"Description": "Source Code",
					"SourceBundle": {
						"S3Bucket": { "Ref": "S3Bucket" },
						"S3Key": { "Ref": "S3ZipKey" }
					}
				}
			},
			"ElasticBeanstalkConfigurationTemplate": {
				"Type": "AWS::ElasticBeanstalk::ConfigurationTemplate",
				"DependsOn": [ "ElasticBeanstalkProfile" ],
				"Properties": {
					"Description": "Semaphore CD Configuration Template",
					"ApplicationName": { "Ref": "ElasticBeanstalkApplication" },
					"SolutionStackName": "64bit Amazon Linux 2016.03 v2.1.0 running Docker 1.9.1",
					"OptionSettings": [
						{
							"Namespace": "aws:elasticbeanstalk:environment",
							"OptionName": "EnvironmentType",
							"Value": "LoadBalanced"
						},
						{
							"Namespace": "aws:elasticbeanstalk:application",
							"OptionName": "Application Healthcheck URL",
							"Value": { "Ref": "HealthCheckPath" }
						},
						{
							"Namespace": "aws:autoscaling:launchconfiguration",
							"OptionName": "IamInstanceProfile",
							"Value": { "Fn::GetAtt": [ "ElasticBeanstalkProfile", "Arn" ] }
						},
						{
							"Namespace": "aws:elasticbeanstalk:application:environment",
							"OptionName": "RACK_ENV",
							"Value": { "Ref": "RackEnv" }
						}
					]
				}
			},
			"ElasticBeanstalkEnvironment": {
				"Type": "AWS::ElasticBeanstalk::Environment",
				"Properties": {
					"Description": { "Ref": "RackEnv" },
					"ApplicationName": { "Ref": "ElasticBeanstalkApplication" },
					"TemplateName": { "Ref": "ElasticBeanstalkConfigurationTemplate" },
					"VersionLabel": { "Ref": "ElasticBeanstalkVersion" },
					"Tier": {
						"Type": "Standard",
						"Name": "WebServer"
					}
				}
			}
		},
		"Outputs": {
			"Application": {
				"Description": "ElasticBeanstalk Application",
				"Value": {
					"Ref": "ElasticBeanstalkApplication"
				}
			}
		}
	}

This templates creates the ElasticBeanstalk application and properly
configured enviornment. It uses an IAM Instance Profile to grant
appropriate permissions to the instances. Finally it outputs the
complete URL to the application. This can be opened in your browser.

Let's move onto the Ansible playbook changes

	- name: Create scratch dir for release artifact
		command: "mktemp -d"
		register: tmp_dir
		changed_when: False

	- name: Create Dockerrun.aws.json for release artifact
		template:
			src: files/Dockerrun.aws.json
			dest: "{{ tmp_dir.stdout }}/Dockerrun.aws.json"
		vars:
			image: "{{ prereqs.stack_outputs.Repository }}:{{ artifact_hash.stdout }}"

	- name: Create release zip file
		command: "zip -r {{ tmp_dir.stdout }}/release.zip ."
		args:
			chdir: "{{ tmp_dir.stdout }}"
		changed_when: False

	- name: Upload release zip to S3
		s3:
			region: "{{ aws_region }}"
			mode: put
			src: "{{ tmp_dir.stdout }}/release.zip"
			bucket: "{{ prereqs.stack_outputs.S3Bucket }}"
			object: "{{ app_name }}-{{ artifact_hash.stdout }}.zip"

	- name: Deploy application stack
		cloudformation:
			state: present
			stack_name: "{{ app_stack_name }}"
			region: "{{ aws_region }}"
			disable_rollback: true
			template: "cloudformation/app.json"
			template_parameters:
				S3Bucket: "{{ prereqs.stack_outputs.S3Bucket }}"
				S3ZipKey: "{{ app_name }}-{{ artifact_hash.stdout }}.zip"
				RackEnv: "{{ environment_name }}"
				HealthCheckPath: "/ping"

The task names should call out the process. The ElasticBeanstalk
specific `Dockerrun.aws.json` is created from an Ansible template. The
`image` variable is generated based some existing variables. Then a
zip file is uploaded to S3 and the appropriate parameters are passed
to the application template.

Now go ahead and push your code again and wait a bit. Initial
provisioning can be a bit slow but it will work. Then open the
ElasticBeanstalk URL and you should see "Hello World". Welcome to
continuous deployment.

[eb]: placeholder
[cf]: placeholder
[cloudformation]: placeholder
[ruby image]: placeholder
[source]: placeholder
