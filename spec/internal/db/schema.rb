# frozen_string_literal: true

# Create Active Storage tables
ActiveRecord::Schema.define do
  create_table :active_storage_blobs, force: true do |t|
    t.string   :key,          null: false
    t.string   :filename,     null: false
    t.string   :content_type
    t.text     :metadata
    t.string   :service_name, null: false
    t.bigint   :byte_size,    null: false
    t.string   :checksum
    t.integer  :reference_count, default: 0, null: false
    t.datetime :created_at, null: false

    t.index [:key], unique: true
    t.index %i[checksum service_name], name: "index_active_storage_blobs_on_checksum_and_service"
  end

  create_table :active_storage_attachments, force: true do |t|
    t.string     :name,     null: false
    t.references :record,   null: false, polymorphic: true, index: false
    t.references :blob,     null: false, index: true

    t.datetime :created_at, null: false

    t.index %i[record_type record_id name blob_id], name: "index_active_storage_attachments_uniqueness",
                                                    unique: true
  end

  create_table :users, force: true do |t|
    t.string :name
    t.timestamps
  end

  create_table :posts, force: true do |t|
    t.string :title
    t.timestamps
  end

  create_table :products, force: true do |t|
    t.string :name
    t.timestamps
  end

  create_table :action_text_rich_texts, force: true do |t|
    t.string     :name, null: false
    t.text       :body
    t.references :record, null: false, polymorphic: true, index: false
    t.timestamps

    t.index %i[record_type record_id name], name: "index_action_text_rich_texts_uniqueness",
                                            unique: true
  end

  create_table :articles, force: true do |t|
    t.string :title
    t.timestamps
  end
end
