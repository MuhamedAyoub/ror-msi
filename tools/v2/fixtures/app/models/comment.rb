class Comment
  belongs_to :commentable, polymorphic: true   # R8: must resolve to {Post, Article}
end
