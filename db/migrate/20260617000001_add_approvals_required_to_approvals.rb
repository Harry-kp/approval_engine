class AddApprovalsRequiredToApprovals < ActiveRecord::Migration[8.1]
  # How many of an approval's parallel tracks must approve for the whole
  # approval to approve — the gather consensus, the across-tracks twin of a
  # layer's `approvals_required`. Defaults to "all" so existing approvals keep
  # their current unanimity behaviour (every track must approve; any hard
  # rejection that makes "all" unreachable fails the approval).
  def change
    add_column :approval_engine_approvals, :approvals_required, :string, null: false, default: "all"

    add_check_constraint :approval_engine_approvals,
                         "approvals_required ~ '^([1-9][0-9]*%?|any|all|majority)$'",
                         name: "chk_approval_engine_approval_approvals_required"
  end
end
