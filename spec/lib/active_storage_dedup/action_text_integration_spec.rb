# frozen_string_literal: true

require "stringio"

RSpec.describe "ActionText integration" do
  before do
    ActiveStorageDedup.configuration.enabled = true
    ActiveStorageDedup.configuration.deduplicate_by_default = true
    ActiveStorageDedup.configuration.auto_purge_orphans = true
  end

  describe "embedding blobs in rich text" do
    it "creates an ActiveStorage::Attachment for embedded blobs" do
      blob = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("image data"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      article = Article.create!(title: "Test")
      article.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob.attachable_sgid}\"></action-text-attachment>"
      )
      article.save!

      attachment = ActiveStorage::Attachment.last
      expect(attachment.record_type).to eq("ActionText::RichText")
      expect(attachment.name).to eq("embeds")
      expect(attachment.blob_id).to eq(blob.id)
    end

    it "increments reference_count when embedded in rich text" do
      blob = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("image data"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      article = Article.create!(title: "Test")

      expect do
        article.content = ActionText::Content.new(
          "<action-text-attachment sgid=\"#{blob.attachable_sgid}\"></action-text-attachment>"
        )
        article.save!
      end.to change { blob.reload.reference_count }.from(0).to(1)
    end
  end

  describe "shared blobs across rich text and regular attachments" do
    it "tracks reference_count across both ActionText and has_one_attached" do
      blob = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("shared content"),
        filename: "shared.jpg",
        content_type: "image/jpeg"
      )

      # Attach via has_one_attached
      user = User.create!(name: "Test User")
      user.avatar.attach(blob)
      expect(blob.reload.reference_count).to eq(1)

      # Embed in ActionText
      article = Article.create!(title: "Test")
      article.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob.attachable_sgid}\"></action-text-attachment>"
      )
      article.save!
      expect(blob.reload.reference_count).to eq(2)

      # Remove the regular attachment — blob should survive
      user.avatar.attachment.destroy
      expect(ActiveStorage::Blob.exists?(blob.id)).to be true
      expect(blob.reload.reference_count).to eq(1)
    end
  end

  describe "removing embeds from rich text" do
    it "decrements reference_count when embed is removed from content" do
      blob = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("image data"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      article = Article.create!(title: "Test")
      article.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob.attachable_sgid}\"></action-text-attachment>"
      )
      article.save!
      expect(blob.reload.reference_count).to eq(1)

      # Update content to remove the embed
      article.update!(content: "Just plain text now")

      expect(ActiveStorage::Blob.exists?(blob.id)).to be false
    end

    it "keeps blob when only one of multiple embeds is removed" do
      blob = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("image data"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      article1 = Article.create!(title: "Article 1")
      article1.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob.attachable_sgid}\"></action-text-attachment>"
      )
      article1.save!

      article2 = Article.create!(title: "Article 2")
      article2.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob.attachable_sgid}\"></action-text-attachment>"
      )
      article2.save!

      expect(blob.reload.reference_count).to eq(2)

      # Remove embed from article1 only
      article1.update!(content: "No more image")

      expect(ActiveStorage::Blob.exists?(blob.id)).to be true
      expect(blob.reload.reference_count).to eq(1)
    end
  end

  describe "DeduplicationJob with ActionText" do
    it "skips blobs referenced by ActionText to avoid stale sgids" do
      # Disable dedup to simulate a race condition creating duplicate blobs
      ActiveStorageDedup.configuration.enabled = false

      blob1 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      blob2 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      ActiveStorageDedup.configuration.enabled = true

      # Embed each blob in a different article
      article1 = Article.create!(title: "Article 1")
      article1.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob1.attachable_sgid}\"></action-text-attachment>"
      )
      article1.save!

      article2 = Article.create!(title: "Article 2")
      article2.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob2.attachable_sgid}\"></action-text-attachment>"
      )
      article2.save!

      expect(ActiveStorage::Blob.count).to eq(2)

      # Run dedup — should skip both blobs since they're referenced by ActionText
      ActiveStorageDedup::DeduplicationJob.perform_now

      # Both blobs should still exist
      expect(ActiveStorage::Blob.count).to eq(2)
      expect(ActiveStorage::Blob.exists?(blob1.id)).to be true
      expect(ActiveStorage::Blob.exists?(blob2.id)).to be true
    end

    it "merges non-ActionText duplicates even when ActionText blobs exist in same group" do
      ActiveStorageDedup.configuration.enabled = false

      blob1 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      blob2 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      blob3 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )

      ActiveStorageDedup.configuration.enabled = true

      # blob1 is referenced by ActionText — should be skipped
      article = Article.create!(title: "Test")
      article.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob1.attachable_sgid}\"></action-text-attachment>"
      )
      article.save!

      # blob2 and blob3 are regular attachments — should be merged
      user1 = User.create!(name: "User 1")
      user1.avatar.attach(blob2)

      user2 = User.create!(name: "User 2")
      user2.avatar.attach(blob3)

      expect(ActiveStorage::Blob.count).to eq(3)

      ActiveStorageDedup::DeduplicationJob.perform_now

      # blob1 (ActionText) untouched, blob3 merged into blob2
      expect(ActiveStorage::Blob.exists?(blob1.id)).to be true
      expect(ActiveStorage::Blob.exists?(blob2.id)).to be true
      expect(ActiveStorage::Blob.exists?(blob3.id)).to be false
      expect(user2.reload.avatar.blob_id).to eq(blob2.id)
    end
  end

  describe "deduplication at upload time with ActionText" do
    it "reuses existing blob when same content is embedded" do
      blob1 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo1.jpg",
        content_type: "image/jpeg"
      )

      # Second upload with same content should reuse blob1
      blob2 = ActiveStorage::Blob.create_after_unfurling!(
        io: StringIO.new("same content"),
        filename: "photo2.jpg",
        content_type: "image/jpeg"
      )

      # Dedup at upload time means both are the same blob
      expect(blob1.id).to eq(blob2.id)
      expect(ActiveStorage::Blob.count).to eq(1)

      # Both articles share the same blob and sgid — no stale reference issue
      article1 = Article.create!(title: "Article 1")
      article1.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob1.attachable_sgid}\"></action-text-attachment>"
      )
      article1.save!

      article2 = Article.create!(title: "Article 2")
      article2.content = ActionText::Content.new(
        "<action-text-attachment sgid=\"#{blob2.attachable_sgid}\"></action-text-attachment>"
      )
      article2.save!

      expect(blob1.reload.reference_count).to eq(2)
    end
  end
end
