# module "test-ops" {
#   source  = "mineiros-io/repository/github"
#   version = "0.18.0"
#
#   name         = "test-ops"
#   description  = "Test repo"
#   topics       = []
#   homepage_url = ""
#   visibility   = "public"
#
#   auto_init              = true
#   allow_merge_commit     = false
#   allow_squash_merge     = true
#   allow_auto_merge       = true
#   delete_branch_on_merge = true
#
#   has_issues   = true
#   has_wiki     = false
#   has_projects = false
#   is_template  = false
#
#   # plaintext_secrets = {}
#
#   issue_labels_merge_with_github_labels = false
#   issue_labels = concat(
#     local.default_issue_labels
#   )
# }
