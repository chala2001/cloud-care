# Inputs for the serverless-contact stack.
# These emails are intentionally NOT secrets (they're just verified SES
# identity addresses), so we commit them so CI can apply this stack.
# If you want to keep them out of git, switch to TF_VAR_* env vars in the
# Terraform workflow instead.
sender_email    = "chalakasamith+sender@gmail.com"
recipient_email = "chalakasamith@gmail.com"
