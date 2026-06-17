class AddApprovalsRequiredToApprovals < ActiveRecord::Migration[7.0]
  # The gather consensus: how many of an approval's parallel tracks must approve.
  # Defaults to "all" so existing approvals keep their unanimity behaviour.
  def change
    add_column :approval_engine_approvals, :approvals_required, :string, null: false, default: "all"

    add_check_constraint :approval_engine_approvals,
                         "approvals_required ~ '^([1-9][0-9]*%?|any|all|majority)$'",
                         name: "chk_approval_engine_approval_approvals_required"
  end
end
