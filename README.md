# Site-Specific DC/OS Terraform Module
This module was forked from [Miguel's DC/OS Terraform code](https://github.com/bernadinm/terraform-dcos) and modified to integrate with users who leveage [Terraform remote state](https://www.terraform.io/docs/providers/terraform/d/remote_state.html) in their deployments and want to manage the VPC infrastructure on their own. 

# How To Use This Module
The module makes a few assumptions about your deployment:
1. The VPC is managed from remote state and has the following outputs:
	- `vpc_id`: a **string** which corresponds to `aws_vpc.<name>.id`
	- `public_subnet_ids`: an **array** which correspond to `aws_subnet.<name>.id` for your public subnets. 
	- `private_subnet_ids`: an **array** which correspond to `aws_subnet.<name>.id` for your privatre subnets. 
2. The remote state is stored in S3. The module requires these variable be set:
```
data "terraform_remote_state" "vpc" {
  backend     = "s3"
  environment = "${var.vpc_remote_state_terraform_environment}"

  config {
    bucket  = "${var.vpc_remote_state_s3_bucket}"
    key     = "${var.vpc_remote_state_s3_key}"
    region  = "${var.vpc_remote_state_s3_region}"
    profile = "${var.vpc_remote_state_aws_profile}"
  }
}
```
3. This module assumes you're using a SSH bastion host to access the VPC
	- https://www.terraform.io/docs/provisioners/connection.html#bastion_host
	- https://en.wikipedia.org/wiki/Bastion_host

To run this module, you can call it from your site-specific code base like this:
```
module "dcos" {
  source = "github.com/malnick/terraform-dcos/aws"

  vpc_remote_state_s3_bucket             = "<MY_COMPANY_BUCKET"
  vpc_remote_state_s3_key                = "<MY_VPC>/vpc.tfstate"
  vpc_remote_state_s3_region             = "<MY_REGION>"
  vpc_remote_state_aws_profile           = "<MY_AWS_PROFILE_NAME>" # See http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html
  vpc_remote_state_terraform_environment = "${terraform.env}" # See https://www.terraform.io/docs/state/environments.html
  bastion_host                           = "<MY_BASTION_HOST_IP>"
  bastion_user                           = "<MY_BASTION_HOST_USER" # Not the user for DC/OS

  key_name   = "<MY_KEY_NAME_FOR_DCOS_HOSTS>"
  aws_region = "<MY_VPC_REGION>"
  os         = "centos_7.2"
  owner      = "<MY_NAME>"
}

There is a slew of other configurations you can run to customize this module, please refer to the variables.tf for options. 
