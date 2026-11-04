class User
  has_many :posts
  has_many :images          # C5: must resolve to Image, not "Imag"
  has_many :notes           # C5: Note, not "Not"

  def notify_weekly
    puts "weekly"
  end
end
