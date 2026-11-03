# Where a feature request stands. The owner hands kogut a feature with the label
# kogut-feature, kogut answers with a plan, and only the owner's label
# kogut-plan-approved, added after that plan, lets it write code. signals.jq and
# kogut_feature_state in lib.sh both ask this, so the digest and the scripts that
# act cannot disagree.
#
# The input is an issue: {labeled, approvals: [{actor, at}], labels: [{name}],
# comments: [{author: {login}, createdAt, body}]}, where labeled lists who added
# kogut-feature and approvals who added kogut-plan-approved.
#   not-enabled   the repository is not in policy.feature.repos
#   unauthorized  the latest kogut-feature label is not the owner's
#   in-progress   a kogut PR names the issue
#   plan          kogut owes a plan: there is none, or the owner answered the last one
#   owner         the plan waits for the owner
#   build         the owner approved the latest plan, so kogut may write code
#
# A plan is the App's comment with the marker, so nobody else can post one. An
# approval counts only if it is the owner's, newer than the latest plan, and the
# label is still on the issue: a new plan needs a new approval.
def feature_needs($owner; $app; $enabled; $prs):
  ([.labeled[]?] | sort_by(.at) | last) as $label
  | ([.comments[]?
      | select((.author.login | IN($app, "\($app)[bot]", "app/\($app)"))
          and ((.body // "") | contains("<!-- kogut-plan -->")))
      | .createdAt] | max) as $planned
  | ([.approvals[]? | select(.actor == $owner) | .at] | max) as $approved
  | ([.comments[]? | select(.author.login == $owner) | .createdAt] | max) as $spoke
  | if ($enabled | not) then "not-enabled"
    elif $label.actor != $owner then "unauthorized"
    elif $prs != [] then "in-progress"
    elif $planned == null then "plan"
    elif any(.labels[]?; .name == "kogut-plan-approved") and $approved != null and $approved > $planned then "build"
    elif $spoke != null and $spoke > $planned then "plan"
    else "owner" end;
