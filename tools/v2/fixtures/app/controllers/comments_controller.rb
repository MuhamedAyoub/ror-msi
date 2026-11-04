class CommentsController
  def create
    @comment = Comment.find(1)     # L0/R10: lookup edge -> Comment
    @comment.commentable           # R8 receiver: union {Post, Article}, split weight
    CleanupJob.perform_later(1)    # R18: exact edge -> CleanupJob only
    something.perform(2)           # C1 probe: unknown receiver + L4 homonym
                                   #   -> must NOT edge to both jobs at weight 1
  end
end
