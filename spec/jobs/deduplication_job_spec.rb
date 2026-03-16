# frozen_string_literal: true

require "stringio"

RSpec.describe ActiveStorageDedup::DeduplicationJob do
  let(:checksum) { Digest::MD5.base64digest("test content") }
  let(:service_name) { "test" } # Use default test service

  describe "#perform" do
    context "when no duplicates exist" do
      it "does nothing" do
        blob = ActiveStorage::Blob.create!(
          key: "test-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name
        )

        expect do
          described_class.perform_now
        end.not_to(change { ActiveStorage::Blob.count })

        expect(ActiveStorage::Blob.exists?(blob.id)).to be true
      end
    end

    context "when duplicates exist" do
      let!(:keeper) do
        ActiveStorage::Blob.create!(
          key: "keeper-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 1.hour.ago
        )
      end

      let!(:duplicate1) do
        ActiveStorage::Blob.create!(
          key: "dup1-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 30.minutes.ago
        )
      end

      let!(:duplicate2) do
        ActiveStorage::Blob.create!(
          key: "dup2-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 10.minutes.ago
        )
      end

      it "keeps the oldest blob and removes duplicates" do
        described_class.perform_now

        expect(ActiveStorage::Blob.exists?(keeper.id)).to be true
        expect(ActiveStorage::Blob.exists?(duplicate1.id)).to be false
        expect(ActiveStorage::Blob.exists?(duplicate2.id)).to be false
      end

      it "reduces total blob count" do
        expect do
          described_class.perform_now
        end.to change { ActiveStorage::Blob.count }.from(3).to(1)
      end

      it "moves attachments from duplicates to keeper" do
        user1 = User.create!(name: "User 1")
        user2 = User.create!(name: "User 2")

        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user1,
          blob: duplicate1
        )

        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user2,
          blob: duplicate2
        )

        expect(keeper.attachments.count).to eq(0)

        described_class.perform_now

        keeper.reload
        expect(keeper.attachments.count).to eq(2)
        expect(user1.reload.avatar.blob.id).to eq(keeper.id)
        expect(user2.reload.avatar.blob.id).to eq(keeper.id)
      end

      it "updates reference_count on keeper" do
        user1 = User.create!(name: "User 1")
        user2 = User.create!(name: "User 2")
        user3 = User.create!(name: "User 3")

        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user1,
          blob: keeper
        )
        keeper.update_column(:reference_count, 1)

        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user2,
          blob: duplicate1
        )
        duplicate1.update_column(:reference_count, 1)

        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user3,
          blob: duplicate2
        )
        duplicate2.update_column(:reference_count, 1)

        described_class.perform_now

        keeper.reload
        expect(keeper.reference_count).to eq(3)
      end
    end

    context "when duplicates have attachments" do
      let!(:keeper) do
        ActiveStorage::Blob.create!(
          key: "keeper-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 1.hour.ago
        )
      end

      let!(:duplicate) do
        ActiveStorage::Blob.create!(
          key: "dup-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 30.minutes.ago
        )
      end

      it "handles errors gracefully" do
        user = User.create!(name: "Test User")
        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user,
          blob: duplicate
        )

        # Stub increment! on the keeper to simulate a failure during merge
        allow_any_instance_of(ActiveStorage::Blob).to receive(:increment!).and_raise(StandardError, "Test error")

        expect do
          described_class.perform_now
        end.not_to raise_error

        # Duplicate should still exist since merge failed before delete
        expect(ActiveStorage::Blob.exists?(duplicate.id)).to be true
      end

      it "does not purge a duplicate that still has attachments" do
        user = User.create!(name: "Test User")
        ActiveStorage::Attachment.create!(
          name: "avatar",
          record: user,
          blob: duplicate
        )

        job = described_class.new

        # Simulate a partial failure: attachments not moved but no error raised.
        # The safety check should prevent purging the blob.
        allow(duplicate.attachments).to receive(:update_all)

        job.send(:merge_duplicate, keeper, duplicate)

        # Duplicate must still exist — its attachment wasn't moved
        expect(ActiveStorage::Blob.exists?(duplicate.id)).to be true
        expect(user.reload.avatar.blob.id).to eq(duplicate.id)
      end
    end

    context "when removing duplicates" do
      it "purges the duplicate blob record and its storage file" do
        keeper = ActiveStorage::Blob.create!(
          key: "keeper-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 1.hour.ago
        )

        duplicate = ActiveStorage::Blob.create!(
          key: "different-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: service_name,
          created_at: 30.minutes.ago
        )

        # Duplicate blobs always have different storage keys (unique index),
        # so purge is always safe — it cleans up both the record and the file
        expect_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_call_original

        described_class.perform_now

        expect(ActiveStorage::Blob.exists?(keeper.id)).to be true
        expect(ActiveStorage::Blob.exists?(duplicate.id)).to be false
      end
    end

    context "with different services" do
      it "only merges blobs from the same service" do
        local_blob1 = ActiveStorage::Blob.create!(
          key: "local-key-1",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: "local",
          created_at: 1.hour.ago
        )

        local_blob2 = ActiveStorage::Blob.create!(
          key: "local-key-2",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: "local",
          created_at: 30.minutes.ago
        )

        s3_blob = ActiveStorage::Blob.create!(
          key: "s3-key",
          filename: "test.txt",
          byte_size: 100,
          checksum: checksum,
          service_name: "s3",
          created_at: 30.minutes.ago
        )

        described_class.perform_now

        # local_blob2 should be merged into local_blob1
        expect(ActiveStorage::Blob.exists?(local_blob1.id)).to be true
        expect(ActiveStorage::Blob.exists?(local_blob2.id)).to be false
        # s3_blob is the only one for its service, should remain
        expect(ActiveStorage::Blob.exists?(s3_blob.id)).to be true
      end
    end
  end
end
