module Api
  module V1
    class User            # C2: must stay a distinct node from ::User
      def sync_remote(a)
      end
    end
  end
end
