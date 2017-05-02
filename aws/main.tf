# Specify the provider and access details
provider "aws" {
  region = "${var.aws_region}"
}

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

# Runs a local script to return the current user in bash
data "external" "whoami" {
  program = ["${path.module}/scripts/local/whoami.sh"]
}

data "template_file" "cluster-name" {
  # template = "$${deployment}-tf$${uuid}"
  template = "dcos-$${deployment}"

  vars {
    deployment = "${var.deployment}"

    #   uuid     = "${substr(md5(data.terraform_remote_state.vpc.vpc_id),0,4)}"
  }
}

# Create DCOS Bucket regardless of what exhibitor backend was chosen
resource "aws_s3_bucket" "dcos_bucket" {
  bucket        = "${var.master_state_s3_bucket_name}" #"blueowl-dcos-${var.deployment}-master-state"
  acl           = "private"
  force_destroy = "true"

  tags {
    Name    = "${data.template_file.cluster-name.rendered}-bucket"
    cluster = "${data.template_file.cluster-name.rendered}"
  }
}

# Reattach the internal ELBs to the master if they change
resource "aws_elb_attachment" "private-master-elb" {
  count    = "${var.num_of_masters}"
  elb      = "${aws_elb.private-master-elb.id}"
  instance = "${element(aws_instance.master.*.id, count.index)}"
}

# Internal Load Balancer Access
# Mesos Master, Zookeeper, Exhibitor, Adminrouter, Marathon
resource "aws_elb" "private-master-elb" {
  name            = "${var.deployment}-mstr-private"
  internal        = true
  subnets         = ["${data.terraform_remote_state.vpc.private_subnet_ids}"]
  security_groups = ["${var.dcos_master_internal_elb_security_group_id}"]
  instances       = ["${aws_instance.master.*.id}"]

  listener {
    lb_port           = 5050
    instance_port     = 5050
    lb_protocol       = "http"
    instance_protocol = "http"
  }

  listener {
    lb_port           = 2181
    instance_port     = 2181
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 8181
    instance_port     = 8181
    lb_protocol       = "http"
    instance_protocol = "http"
  }

  listener {
    lb_port           = 80
    instance_port     = 80
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 443
    instance_port     = 443
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 8080
    instance_port     = 8080
    lb_protocol       = "http"
    instance_protocol = "http"
  }

  lifecycle {
    ignore_changes = ["name"]
  }
}

resource "aws_elb" "linkerd-elb-public" {
  name            = "${var.deployment}-linkerd-public"
  depends_on      = ["aws_instance.agent"]
  subnets         = ["${data.terraform_remote_state.vpc.public_subnet_ids}"]
  security_groups = ["${var.linkerd_public_elb_security_group_id}"]
  instances       = ["${aws_instance.public-agent.*.id}"]

  listener {
    lb_port           = 9990
    instance_port     = 9990
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 4140
    instance_port     = 4140
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "TCP:4140"
    interval            = 5
  }

  lifecycle {
    ignore_changes = ["name"]
  }
}

resource "aws_elb" "linkerd-elb-private" {
  name            = "${var.deployment}-linkerd-private"
  depends_on      = ["aws_instance.agent"]
  subnets         = ["${data.terraform_remote_state.vpc.public_subnet_ids}"]
  security_groups = ["${var.linkerd_private_elb_security_group_id}"]
  instances       = ["${aws_instance.private-agent.*.id}"]

  listener {
    lb_port           = 9990
    instance_port     = 9990
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 4140
    instance_port     = 4140
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "TCP:4140"
    interval            = 5
  }

  lifecycle {
    ignore_changes = ["name"]
  }
}

# Provide tested AMI and user from listed region startup commands
module "aws-tested-oses" {
  source = "./modules/dcos-tested-aws-oses"
  os     = "${var.os}"
  region = "${var.aws_region}"
}

resource "aws_instance" "master" {
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  connection {
    # The default username for our AMI
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    agent        = true
  }

  root_block_device {
    volume_size = "${var.instance_disk_size}"
  }

  count         = "${var.num_of_masters}"
  instance_type = "${var.aws_master_instance_type}"

  tags {
    deployment = "${var.deployment}"
    expiration = "${var.expiration}"
    Name       = "${data.template_file.cluster-name.rendered}-master-${count.index + 1}"
    cluster    = "${data.template_file.cluster-name.rendered}"
  }

  # Lookup the correct AMI based on the region
  # we specified
  ami = "${module.aws-tested-oses.aws_ami}"

  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${var.dcos_master_security_group_id}"]

  # OS init script
  provisioner "file" {
    content     = "${module.aws-tested-oses.os-setup}"
    destination = "/tmp/os-setup.sh"
  }

  subnet_id = "${element(data.terraform_remote_state.vpc.private_subnet_ids, count.index)}"

  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /tmp/os-setup.sh",
      "sudo bash /tmp/os-setup.sh",
    ]
  }

  lifecycle {
    ignore_changes = ["tags.Name", "tags.cluster"]
  }
}

resource "aws_instance" "agent" {
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  connection {
    # The default username for our AMI
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"

    # The connection will use the local SSH agent for authentication.
  }

  root_block_device {
    volume_size = "${var.instance_disk_size}"
  }

  count         = "${var.num_of_private_agents}"
  instance_type = "${var.aws_agent_instance_type}"

  tags {
    deployment = "${var.deployment}"
    Name       = "${data.template_file.cluster-name.rendered}-pvtagt-${count.index + 1}"
    cluster    = "${data.template_file.cluster-name.rendered}"
  }

  # Lookup the correct AMI based on the region
  # we specified
  ami = "${module.aws-tested-oses.aws_ami}"

  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${var.dcos_private_slave_security_group_id}"]

  subnet_id = "${element(data.terraform_remote_state.vpc.private_subnet_ids, count.index)}"

  # OS init script
  provisioner "file" {
    content     = "${module.aws-tested-oses.os-setup}"
    destination = "/tmp/os-setup.sh"
  }

  # We run a remote provisioner on the instance after creating it.
  # In this case, we just install nginx and start it. By default,
  # this should be on port 80
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /tmp/os-setup.sh",
      "sudo bash /tmp/os-setup.sh",
    ]
  }

  lifecycle {
    ignore_changes = ["tags.Name"]
  }
}

resource "aws_instance" "public-agent" {
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  connection {
    # The default username for our AMI
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"

    # The connection will use the local SSH agent for authentication.
  }

  root_block_device {
    volume_size = "${var.instance_disk_size}"
  }

  count         = "${var.num_of_public_agents}"
  instance_type = "${var.aws_public_agent_instance_type}"

  tags {
    deployment = "${var.deployment}"
    Name       = "${data.template_file.cluster-name.rendered}-pubagt-${count.index + 1}"
    cluster    = "${data.template_file.cluster-name.rendered}"
  }

  # Lookup the correct AMI based on the region
  # we specified
  ami = "${module.aws-tested-oses.aws_ami}"

  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${var.dcos_public_slave_security_group_id}"]

  # Public slaves are deployed to the private subnet still and are only
  # available via the linkerd ELB.
  subnet_id = "${data.terraform_remote_state.vpc.private_subnet_ids[0]}"

  # OS init script
  provisioner "file" {
    content     = "${module.aws-tested-oses.os-setup}"
    destination = "/tmp/os-setup.sh"
  }

  # We run a remote provisioner on the instance after creating it.
  # In this case, we just install nginx and start it. By default,
  # this should be on port 80
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /tmp/os-setup.sh",
      "sudo bash /tmp/os-setup.sh",
    ]
  }

  lifecycle {
    ignore_changes = ["tags.Name"]
  }
}

resource "aws_instance" "bootstrap" {
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  connection {
    # The default username for our AMI
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
  }

  root_block_device {
    volume_size = "${var.instance_disk_size}"
  }

  instance_type = "${var.aws_bootstrap_instance_type}"

  tags {
    deployment = "${var.deployment}"
    Name       = "${data.template_file.cluster-name.rendered}-bootstrap"
    cluster    = "${data.template_file.cluster-name.rendered}"
  }

  # Lookup the correct AMI based on the region
  # we specified
  ami = "${module.aws-tested-oses.aws_ami}"

  key_name               = "${var.key_name}"
  vpc_security_group_ids = ["${var.dcos_bootstrap_security_group_id}"]

  subnet_id = "${data.terraform_remote_state.vpc.private_subnet_ids[0]}"

  # DCOS ip detect script
  provisioner "file" {
    source      = "${path.module}/${var.ip-detect["aws"]}"
    destination = "/tmp/ip-detect"
  }

  # OS init script
  provisioner "file" {
    content     = "${module.aws-tested-oses.os-setup}"
    destination = "/tmp/os-setup.sh"
  }

  # We run a remote provisioner on the instance after creating it.
  # In this case, we just install nginx and start it. By default,
  # this should be on port 80
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /tmp/os-setup.sh",
      "sudo bash /tmp/os-setup.sh",
    ]
  }

  lifecycle {
    ignore_changes = ["tags.Name"]
  }
}

# Create DCOS Mesos Master Scripts to execute
module "dcos-bootstrap" {
  source                    = "./modules/dcos-core"
  bootstrap_private_ip      = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode         = "${var.state}"
  dcos_version              = "${var.dcos_version}"
  role                      = "dcos-bootstrap"
  dcos_bootstrap_port       = "${var.custom_dcos_bootstrap_port}"
  custom_dcos_download_path = "${var.custom_dcos_download_path}"

  # TODO(bernadinm) Terraform Bug: 9488.  Templates will not accept list, but only strings.
  # Workaround is to flatten the list as a string below. Fix when this is closed.
  dcos_public_agent_list = "\n - ${join("\n - ", aws_instance.public-agent.*.private_ip)}"

  dcos_audit_logging                           = "${var.dcos_audit_logging}"
  dcos_auth_cookie_secure_flag                 = "${var.dcos_auth_cookie_secure_flag}"
  dcos_aws_access_key_id                       = "${var.dcos_aws_access_key_id}"
  dcos_aws_region                              = "${coalesce(var.dcos_aws_region, var.aws_region)}"
  dcos_aws_secret_access_key                   = "${var.dcos_aws_secret_access_key}"
  dcos_aws_template_storage_access_key_id      = "${var.dcos_aws_template_storage_access_key_id}"
  dcos_aws_template_storage_bucket             = "${var.dcos_aws_template_storage_bucket}"
  dcos_aws_template_storage_bucket_path        = "${var.dcos_aws_template_storage_bucket_path}"
  dcos_aws_template_storage_region_name        = "${var.dcos_aws_template_storage_region_name}"
  dcos_aws_template_storage_secret_access_key  = "${var.dcos_aws_template_storage_secret_access_key}"
  dcos_aws_template_upload                     = "${var.dcos_aws_template_upload}"
  dcos_bouncer_expiration_auth_token_days      = "${var.dcos_bouncer_expiration_auth_token_days}"
  dcos_check_time                              = "${var.dcos_check_time}"
  dcos_cluster_docker_credentials              = "${var.dcos_cluster_docker_credentials}"
  dcos_cluster_docker_credentials_dcos_owned   = "${var.dcos_cluster_docker_credentials_dcos_owned}"
  dcos_cluster_docker_credentials_enabled      = "${var.dcos_cluster_docker_credentials_enabled}"
  dcos_cluster_docker_credentials_write_to_etc = "${var.dcos_cluster_docker_credentials_write_to_etc}"
  dcos_cluster_name                            = "${coalesce(var.dcos_cluster_name, data.template_file.cluster-name.rendered)}"
  dcos_customer_key                            = "${var.dcos_customer_key}"
  dcos_dns_search                              = "${var.dcos_dns_search}"
  dcos_docker_remove_delay                     = "${var.dcos_docker_remove_delay}"
  dcos_exhibitor_address                       = "${aws_elb.private-master-elb.dns_name}"
  dcos_exhibitor_azure_account_key             = "${var.dcos_exhibitor_azure_account_key}"
  dcos_exhibitor_azure_account_name            = "${var.dcos_exhibitor_azure_account_name}"
  dcos_exhibitor_azure_prefix                  = "${var.dcos_exhibitor_azure_prefix}"
  dcos_exhibitor_explicit_keys                 = "${var.dcos_exhibitor_explicit_keys}"
  dcos_exhibitor_storage_backend               = "${var.dcos_exhibitor_storage_backend}"
  dcos_exhibitor_zk_hosts                      = "${var.dcos_exhibitor_zk_hosts}"
  dcos_exhibitor_zk_path                       = "${var.dcos_exhibitor_zk_path}"
  dcos_gc_delay                                = "${var.dcos_gc_delay}"
  dcos_http_proxy                              = "${var.dcos_http_proxy}"
  dcos_https_proxy                             = "${var.dcos_https_proxy}"
  dcos_log_directory                           = "${var.dcos_log_directory}"
  dcos_master_discovery                        = "${var.dcos_master_discovery}"
  dcos_master_dns_bindall                      = "${var.dcos_master_dns_bindall}"

  # TODO(bernadinm) Terraform Bug: 9488.  Templates will not accept list, but only strings. 
  # Workaround is to flatten the list as a string below. Fix when this is closed.
  dcos_master_list = "\n - ${join("\n - ", aws_instance.master.*.private_ip)}"

  dcos_no_proxy                = "${var.dcos_no_proxy}"
  dcos_num_masters             = "${var.num_of_masters}"
  dcos_oauth_enabled           = "${var.dcos_oauth_enabled}"
  dcos_overlay_config_attempts = "${var.dcos_overlay_config_attempts}"
  dcos_overlay_enable          = "${var.dcos_overlay_enable}"
  dcos_overlay_mtu             = "${var.dcos_overlay_mtu}"
  dcos_overlay_network         = "${var.dcos_overlay_network}"
  dcos_process_timeout         = "${var.dcos_process_timeout}"
  dcos_agent_list              = "\n - ${join("\n - ", aws_instance.agent.*.private_ip)}"

  # TODO(bernadinm) Terraform Bug: 9488.  Templates will not accept list, but only strings.
  # Workaround is to flatten the list as a string below. Fix when this is closed.
  dcos_resolvers = "\n - ${join("\n - ", var.dcos_resolvers)}"

  dcos_rexray_config_filename          = "${var.dcos_rexray_config_filename}"
  dcos_rexray_config_method            = "${var.dcos_rexray_config_method}"
  dcos_s3_bucket                       = "${coalesce(var.dcos_s3_bucket, aws_s3_bucket.dcos_bucket.id)}"
  dcos_s3_prefix                       = "${coalesce(var.dcos_s3_prefix, aws_s3_bucket.dcos_bucket.id)}"
  dcos_security                        = "${var.dcos_security}"
  dcos_superuser_password_hash         = "${var.dcos_superuser_password_hash}"
  dcos_superuser_username              = "${var.dcos_superuser_username}"
  dcos_telemetry_enabled               = "${var.dcos_telemetry_enabled}"
  dcos_use_proxy                       = "${var.dcos_use_proxy}"
  dcos_zk_agent_credentials            = "${var.dcos_zk_agent_credentials}"
  dcos_zk_master_credentials           = "${var.dcos_zk_master_credentials}"
  dcos_zk_super_credentials            = "${var.dcos_zk_super_credentials}"
  dcos_cluster_docker_registry_url     = "${var.dcos_cluster_docker_registry_url}"
  dcos_rexray_config                   = "${var.dcos_rexray_config}"
  dcos_ip_detect_public_contents       = "${var.dcos_ip_detect_public_contents}"
  dcos_cluster_docker_registry_enabled = "${var.dcos_cluster_docker_registry_enabled}"
  dcos_enable_docker_gc                = "${var.dcos_enable_docker_gc}"
  dcos_staged_package_storage_uri      = "${var.dcos_staged_package_storage_uri}"
  dcos_package_storage_uri             = "${var.dcos_package_storage_uri}"
}

resource "null_resource" "bootstrap" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids                         = "${aws_instance.bootstrap.id}"
    dcos_version                                 = "${var.dcos_version}"
    dcos_security                                = "${var.dcos_security}"
    num_of_masters                               = "${var.num_of_masters}"
    dcos_audit_logging                           = "${var.dcos_audit_logging}"
    dcos_auth_cookie_secure_flag                 = "${var.dcos_auth_cookie_secure_flag}"
    dcos_aws_access_key_id                       = "${var.dcos_aws_access_key_id}"
    dcos_aws_region                              = "${coalesce(var.dcos_aws_region, var.aws_region)}"
    dcos_aws_secret_access_key                   = "${var.dcos_aws_secret_access_key}"
    dcos_aws_template_storage_access_key_id      = "${var.dcos_aws_template_storage_access_key_id}"
    dcos_aws_template_storage_bucket             = "${var.dcos_aws_template_storage_bucket}"
    dcos_aws_template_storage_bucket_path        = "${var.dcos_aws_template_storage_bucket_path}"
    dcos_aws_template_storage_region_name        = "${var.dcos_aws_template_storage_region_name}"
    dcos_aws_template_storage_secret_access_key  = "${var.dcos_aws_template_storage_secret_access_key}"
    dcos_aws_template_upload                     = "${var.dcos_aws_template_upload}"
    dcos_bouncer_expiration_auth_token_days      = "${var.dcos_bouncer_expiration_auth_token_days}"
    dcos_check_time                              = "${var.dcos_check_time}"
    dcos_cluster_docker_credentials              = "${var.dcos_cluster_docker_credentials}"
    dcos_cluster_docker_credentials_dcos_owned   = "${var.dcos_cluster_docker_credentials_dcos_owned}"
    dcos_cluster_docker_credentials_enabled      = "${var.dcos_cluster_docker_credentials_enabled}"
    dcos_cluster_docker_credentials_write_to_etc = "${var.dcos_cluster_docker_credentials_write_to_etc}"
    dcos_customer_key                            = "${var.dcos_customer_key}"
    dcos_dns_search                              = "${var.dcos_dns_search}"
    dcos_docker_remove_delay                     = "${var.dcos_docker_remove_delay}"
    dcos_exhibitor_address                       = "${aws_elb.private-master-elb.dns_name}"
    dcos_exhibitor_azure_account_key             = "${var.dcos_exhibitor_azure_account_key}"
    dcos_exhibitor_azure_account_name            = "${var.dcos_exhibitor_azure_account_name}"
    dcos_exhibitor_azure_prefix                  = "${var.dcos_exhibitor_azure_prefix}"
    dcos_exhibitor_explicit_keys                 = "${var.dcos_exhibitor_explicit_keys}"
    dcos_exhibitor_storage_backend               = "${var.dcos_exhibitor_storage_backend}"
    dcos_exhibitor_zk_hosts                      = "${var.dcos_exhibitor_zk_hosts}"
    dcos_exhibitor_zk_path                       = "${var.dcos_exhibitor_zk_path}"
    dcos_gc_delay                                = "${var.dcos_gc_delay}"
    dcos_http_proxy                              = "${var.dcos_http_proxy}"
    dcos_https_proxy                             = "${var.dcos_https_proxy}"
    dcos_log_directory                           = "${var.dcos_log_directory}"
    dcos_master_discovery                        = "${var.dcos_master_discovery}"
    dcos_master_dns_bindall                      = "${var.dcos_master_dns_bindall}"

    # TODO(bernadinm) Terraform Bug: 9488.  Templates will not accept list, but only strings.
    # Workaround is to flatten the list as a string below. Fix when this is closed.
    dcos_no_proxy = "${var.dcos_no_proxy}"

    dcos_num_masters             = "${var.num_of_masters}"
    dcos_oauth_enabled           = "${var.dcos_oauth_enabled}"
    dcos_overlay_config_attempts = "${var.dcos_overlay_config_attempts}"
    dcos_overlay_enable          = "${var.dcos_overlay_enable}"
    dcos_overlay_mtu             = "${var.dcos_overlay_mtu}"
    dcos_overlay_network         = "${var.dcos_overlay_network}"
    dcos_process_timeout         = "${var.dcos_process_timeout}"

    # TODO(bernadinm) Terraform Bug: 9488.  Templates will not accept list, but only strings.
    # Workaround is to flatten the list as a string below. Fix when this is closed.
    dcos_resolvers = "\n - ${join("\n - ", var.dcos_resolvers)}"

    dcos_rexray_config_filename          = "${var.dcos_rexray_config_filename}"
    dcos_rexray_config_method            = "${var.dcos_rexray_config_method}"
    dcos_s3_bucket                       = "${coalesce(var.dcos_s3_bucket, aws_s3_bucket.dcos_bucket.id)}"
    dcos_s3_prefix                       = "${coalesce(var.dcos_s3_prefix, aws_s3_bucket.dcos_bucket.id)}"
    dcos_security                        = "${var.dcos_security}"
    dcos_superuser_password_hash         = "${var.dcos_superuser_password_hash}"
    dcos_superuser_username              = "${var.dcos_superuser_username}"
    dcos_telemetry_enabled               = "${var.dcos_telemetry_enabled}"
    dcos_use_proxy                       = "${var.dcos_use_proxy}"
    dcos_zk_agent_credentials            = "${var.dcos_zk_agent_credentials}"
    dcos_zk_master_credentials           = "${var.dcos_zk_master_credentials}"
    dcos_zk_super_credentials            = "${var.dcos_zk_super_credentials}"
    dcos_cluster_docker_registry_url     = "${var.dcos_cluster_docker_registry_url}"
    dcos_rexray_config                   = "${var.dcos_rexray_config}"
    dcos_ip_detect_public_contents       = "${var.dcos_ip_detect_public_contents}"
    dcos_cluster_docker_registry_enabled = "${var.dcos_cluster_docker_registry_enabled}"
    dcos_enable_docker_gc                = "${var.dcos_enable_docker_gc}"
    dcos_staged_package_storage_uri      = "${var.dcos_staged_package_storage_uri}"
    dcos_package_storage_uri             = "${var.dcos_package_storage_uri}"
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host         = "${aws_instance.bootstrap.private_ip}"
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    agent        = true
  }

  # Generate and upload bootstrap script to node
  provisioner "file" {
    content     = "${module.dcos-bootstrap.script}"
    destination = "run.sh"
  }

  # Install Bootstrap Script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x run.sh",
      "sudo ./run.sh",
    ]
  }

  lifecycle {
    ignore_changes = ["data.template_file.cluster-name.rendered"]
  }
}

# Create DCOS Mesos Master Scripts to execute
module "dcos-mesos-master" {
  source               = "./modules/dcos-core"
  bootstrap_private_ip = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode    = "${var.state}"
  dcos_version         = "${var.dcos_version}"
  role                 = "dcos-mesos-master"
}

resource "null_resource" "master" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids = "${null_resource.bootstrap.id}"
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host         = "${element(aws_instance.master.*.private_ip, count.index)}"
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    agent        = true
  }

  count = "${var.num_of_masters}"

  # Generate and upload Master script to node
  provisioner "file" {
    content     = "${module.dcos-mesos-master.script}"
    destination = "run.sh"
  }

  # Wait for bootstrapnode to be ready
  provisioner "remote-exec" {
    inline = [
      "until $(curl --output /dev/null --silent --head --fail http://${aws_instance.bootstrap.private_ip}/dcos_install.sh); do printf 'waiting for bootstrap node to serve...'; sleep 20; done",
    ]
  }

  # Install Master Script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x run.sh",
      "sudo ./run.sh",
    ]
  }

  # Watch Master Nodes Start
  # Does not work if Terraform is not on the same network as Masters since we've locked down this deployment. 
  #  provisioner "remote-exec" {
  #    inline = [
  #      "until $(curl --output /dev/null --silent --head --fail http://${element(aws_instance.master.*.public_ip, count.index)}/); do printf 'loading DC/OS...'; sleep 10; done",
  #    ]
  #  }
}

# Create DCOS Mesos Agent Scripts to execute
module "dcos-mesos-agent" {
  source               = "./modules/dcos-core"
  bootstrap_private_ip = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode    = "${var.state}"
  dcos_version         = "${var.dcos_version}"
  role                 = "dcos-mesos-agent"
}

# Execute generated script on agent
resource "null_resource" "agent" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids = "${null_resource.bootstrap.id}"
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host         = "${element(aws_instance.agent.*.private_ip, count.index)}"
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    agent        = true
  }

  count = "${var.num_of_private_agents}"

  # Generate and upload Agent script to node
  provisioner "file" {
    content     = "${module.dcos-mesos-agent.script}"
    destination = "run.sh"
  }

  # Wait for bootstrapnode to be ready
  provisioner "remote-exec" {
    inline = [
      "until $(curl --output /dev/null --silent --head --fail http://${aws_instance.bootstrap.private_ip}/dcos_install.sh); do printf 'waiting for bootstrap node to serve...'; sleep 20; done",
    ]
  }

  # Install Slave Node
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x run.sh",
      "sudo ./run.sh",
    ]
  }
}

# Create DCOS Mesos Public Agent Scripts to execute
module "dcos-mesos-agent-public" {
  source               = "./modules/dcos-core"
  bootstrap_private_ip = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode    = "${var.state}"
  dcos_version         = "${var.dcos_version}"
  role                 = "dcos-mesos-agent-public"
}

# Execute generated script on agent
resource "null_resource" "public-agent" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids = "${null_resource.bootstrap.id}"
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host         = "${element(aws_instance.public-agent.*.private_ip, count.index)}"
    user         = "${module.aws-tested-oses.user}"
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    agent        = true
  }

  count = "${var.num_of_public_agents}"

  # Generate and upload Agent script to node
  provisioner "file" {
    content     = "${module.dcos-mesos-agent-public.script}"
    destination = "run.sh"
  }

  # Wait for bootstrapnode to be ready
  provisioner "remote-exec" {
    inline = [
      "until $(curl --output /dev/null --silent --head --fail http://${aws_instance.bootstrap.private_ip}/dcos_install.sh); do printf 'waiting for bootstrap node to serve...'; sleep 20; done",
    ]
  }

  # Install Slave Node
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x run.sh",
      "sudo ./run.sh",
    ]
  }
}
