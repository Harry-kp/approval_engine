# Copied by `rails generate approval_engine:views`.
#
# This file is yours now — restyle it, rename it, add authorization (Pundit,
# etc.). ApprovalEngine provides the mechanism (step.approve! / reject!); the
# user-facing experience is entirely up to you.
class ApprovalsController < ApplicationController
  def index
    # actionable_by includes steps delegated to you, and preloads each step's
    # target so the view can show *what* is awaiting approval without N+1s.
    @pending_steps = ApprovalEngine::Step.actionable_by(current_user)
                                         .includes(track: { approval: :target })
                                         .order(:created_at)
  end

  def approve
    act(:approve!, notice: "Approval recorded.")
  end

  def reject
    act(:reject!, notice: "Rejection recorded.")
  end

  private

  def act(method, notice:)
    step = ApprovalEngine::Step.pending.find(params[:id])
    step.public_send(method, by: current_user, comment: params[:comment])
    redirect_back fallback_location: approvals_path, notice: notice
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: approvals_path, alert: e.message
  end
end
