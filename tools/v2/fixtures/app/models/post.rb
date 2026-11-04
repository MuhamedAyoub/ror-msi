class Post
  belongs_to :user
  has_many :comments, as: :commentable   # R7: declarer of interface
end
