class ReportService
  def call
    user = User.find(1)       # L1: type(user) = User
    user.notify_weekly        # -> edge ReportService -> User (l1_var_typed)
  end
end
