# Inputs for the observability stack.
# The alert email isn't a secret — committing it lets CI plan/apply this stack.
# (If you ever want to keep it out of git, switch to a TF_VAR_alert_email env
# var in the Terraform workflow instead.)
alert_email = "chalakasamith@gmail.com"
