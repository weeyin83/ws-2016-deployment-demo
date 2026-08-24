
export TF_VAR_admin_password='Sandbank_123abc'
terraform plan -out=tfplan
terraform apply tfplan
