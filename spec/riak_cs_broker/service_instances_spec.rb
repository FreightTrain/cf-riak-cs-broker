require 'spec_helper'

RSpec::Matchers.define :have_grant_for do |expected_user_key|
  match do |acl|
    grants = acl['AccessControlList']
    if @permission
      grants.find { |grant| grant['Grantee']['ID'] == expected_user_key && grant['Permission'] == @permission }
    else
      grants.find { |grant| grant['Grantee']['ID'] == expected_user_key }
    end
  end

  chain :with_permission do |permission|
    @permission = permission
  end

  failure_message_for_should do |acl|
    message = "expected a grant with Grantee ID #{expected_user_key}"
    message << " and Permission #{@permission}" if @permission
    message << " to be in #{acl.inspect}"
    message
  end

  failure_message_for_should_not do |acl|
    message = "expected a grant with Grantee ID #{expected_user_key}"
    message << " and Permission #{@permission}" if @permission
    message << " not to be in #{acl.inspect}"
    message
  end
end

shared_examples "it handles timeouts by raising ServiceUnavailableError" do
  it "raises ServiceUnavailableError" do
    expect{ subject }.to raise_error(RiakCsBroker::ServiceInstances::ServiceUnavailableError)
  end
end

describe RiakCsBroker::ServiceInstances do
  class MyError < StandardError
  end

  let(:service_instances) { described_class.new(RiakCsBroker::Config.riak_cs) }
  subject { service_instances }

  describe "#initialize" do
    context "when bucket creation times out" do
      before do
        Fog::Storage::AWS::Mock.any_instance.stub_chain(:directories, :create).and_raise(Excon::Errors::Timeout)
      end

      it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
    end

    it "raises a ClientError if the client fails to initialize" do
      Fog::Storage.stub(:new).and_raise(MyError.new("some-error-message"))

      expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ClientError, "MyError: some-error-message")
    end
  end

  describe "#add" do
    subject { service_instances.add("my-instance") }

    context "when bucket creation times out" do
      before do
        directories = double(:directories)
        directories.stub(:create).with(key: described_class.bucket_name("my-instance")).and_raise(Excon::Errors::Timeout)
        service_instances.storage_client.stub(:directories).and_return(directories)
      end

      it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
    end

    it "creates the requested instance" do
      subject
      expect(service_instances.include?("my-instance")).to be_true
    end

    it "raises a ClientError if the client fails to create a bucket" do
      directories = double(:directories)
      directories.stub(:create).with(key: described_class.bucket_name("my-instance")).and_raise(MyError.new("some-error-message"))
      service_instances.storage_client.stub(:directories).and_return(directories)

      expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ClientError, "MyError: some-error-message")
    end
  end

  describe "#remove" do
    subject { service_instances.remove("my-instance") }

    context "when the instance exists" do
      before do
        service_instances.add("my-instance")
      end

      it "removes the requested instance" do
        expect { subject }.to change { service_instances.include?("my-instance") }.from(true).to(false)
      end

      context "when the instance is not empty" do
        before do
          Fog::Storage::AWS::Mock.any_instance.stub_chain(:directories, :get).and_return(:anything)
          Fog::Storage::AWS::Mock.any_instance.stub_chain(:directories, :create)
          Fog::Storage::AWS::Mock.any_instance.stub_chain(:directories, :destroy).and_raise(Excon::Errors::Conflict.new(nil))
        end

        it "raises InstanceNotEmptyError" do
          expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::InstanceNotEmptyError)
        end
      end

      it "raises a ClientError if the client fails to destroy a bucket" do
        directories = double(:directories).as_null_object
        directories.stub(:destroy).with(described_class.bucket_name("my-instance")).and_raise(MyError.new("some-error-message"))
        service_instances.storage_client.stub(:directories).and_return(directories)

        expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ClientError, "MyError: some-error-message")
      end

      context "when bucket removal times out" do
        before do
          directories = double(:directories).as_null_object
          directories.stub(:destroy).with(described_class.bucket_name("my-instance")).and_raise(Excon::Errors::Timeout)
          service_instances.storage_client.stub(:directories).and_return(directories)
        end

        it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
      end
    end

    context "when the instance does not exist" do
      it "raises InstanceNotFoundError" do
        expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::InstanceNotFoundError)
      end
    end
  end

  describe "#include?" do
    subject { service_instances.include?("my-instance") }

    context "when list bucket times out" do
      before do
        service_instances.storage_client.stub_chain(:directories, :create)
        service_instances.storage_client.stub_chain(:directories, :get).and_raise(Excon::Errors::Timeout)
      end

      it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
    end

    it "does not include any instances that were never created" do
      expect(service_instances.include?("never-created")).to be_false
    end

    it "raises a ClientError if the client fails to look up a bucket" do
      storage = double(:storage).as_null_object
      storage.stub_chain(:directories, :create)
      storage.stub_chain(:directories, :get).and_raise(MyError.new("some-error-message"))

      Fog::Storage.stub(:new).and_return(storage)

      expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ClientError, "MyError: some-error-message")
    end
  end

  describe "#bind" do
    subject { service_instances.bind("my-instance", "some-binding-id") }

    context "when the instance does not exist" do
      it "raises InstanceNotFoundError" do
        expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::InstanceNotFoundError)
      end
    end

    context "when the instance exists" do
      let(:expected_creds) { {
        uri: "http://user-key:user-secret@riakcs.10.244.0.34.xip.io/service-instance-my-instance",
        access_key_id: "user-key",
        secret_access_key: "user-secret"
      } }

      before do
        service_instances.add("my-instance")
      end

      context "and the binding id is not already bound" do
        before do
          response = double(:response, body: {
            'key_id' => 'user-key',
            'key_secret' => 'user-secret',
            'id' => 'user-id'
          })
          service_instances.provision_client.stub(:create_user).and_return(response)
        end

        it "creates a user and returns credentials" do
          expect(subject).to eq(expected_creds)
        end

        it "adds the user to the bucket ACL" do
          subject
          acl = service_instances.storage_client.get_bucket_acl(described_class.bucket_name("my-instance")).body
          expect(acl).to have_grant_for("user-id").with_permission("READ")
          expect(acl).to have_grant_for("user-id").with_permission("WRITE")
        end
      end

      context "and the binding id has already been bound" do
        before do
          service_instances.add("some-other-instance")
          service_instances.bind("some-other-instance", "some-binding-id")
        end

        it "should raise BindingAlreadyExistsError" do
          expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::BindingAlreadyExistsError)
        end
      end

      context "when it is already bound but not stored by the broker" do
        before do
          service_instances.provision_client.stub(:create_user).and_raise(Fog::RiakCS::Provisioning::UserAlreadyExists)
        end

        it "raises BindingAlreadyExistsError" do
          expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::BindingAlreadyExistsError)
        end
      end

      context "when Riak CS is not available" do
        before do
          service_instances.provision_client.stub(:create_user).and_raise(Fog::RiakCS::Provisioning::ServiceUnavailable)
        end

        it "raises ServiceUnavailableError" do
          expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ServiceUnavailableError)
        end
      end

      context "when creating user times out" do
        before do
          service_instances.provision_client.stub(:create_user).and_raise(Excon::Errors::Timeout)
        end

        it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
      end

      it "raises a ClientError if the client fails to create a bucket" do
        service_instances.provision_client.stub(:create_user).and_raise(MyError.new("some-error-message"))

        expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ClientError, "MyError: some-error-message")
      end
    end
  end

  describe '#bound?' do
    subject { service_instances.bound?("binding-id") }

    context "when the binding id has already been bound" do
      before do
        service_instances.add("my-instance")
        service_instances.bind("my-instance", "binding-id")
      end

      it "is true" do
        expect(subject).to be_true
      end
    end

    context "when the binding id has not been bound" do
      it "is false" do
        expect(subject).to be_false
      end
    end

    context "when the binding id has been unbound" do
      before do
        service_instances.add("my-instance")
        service_instances.bind("my-instance", "binding-id")
        service_instances.unbind("my-instance", "binding-id")
      end

      it "is false" do
        expect(subject).to be_false
      end
    end

    context "when binding id lookup times out" do
      before do
        service_instances.storage_client.stub_chain(:directories, :create)
        service_instances.storage_client.stub_chain(:directories, :get, :files, :get).and_raise(Excon::Errors::Timeout)
      end

      it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
    end
  end

  describe "#unbind" do
    subject { service_instances.unbind("my-instance", "some-binding-id") }

    context "when the instance does not exist" do
      it "raises InstanceNotFoundError" do
        expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::InstanceNotFoundError)
      end
    end

    context "when the instance exists" do
      before do
        service_instances.add("my-instance")
      end

      context "when the binding doesn't exist" do
        it "raises BindingNotFoundError" do
          expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::BindingNotFoundError)
        end
      end

      context "when the binding exists" do
        before do
          response = double(:response, body: {
            'key_id' => 'user-key',
            'key_secret' => 'user-secret',
            'id' => 'user-id'
          })
          service_instances.provision_client.stub(:create_user).and_return(response)
          service_instances.bind("my-instance", "some-binding-id")
        end

        it "removes the user from the bucket ACL" do
          subject

          acl = service_instances.storage_client.get_bucket_acl(described_class.bucket_name("my-instance")).body
          expect(acl).not_to have_grant_for("user-id")
        end

        context "when acl times out" do
          before do
            service_instances.storage_client.stub(:get_bucket_acl).and_raise(Excon::Errors::Timeout)
          end

          it_behaves_like "it handles timeouts by raising ServiceUnavailableError"
        end

        it "raises a ClientError if the client fails to create a bucket" do
          service_instances.storage_client.stub(:get_bucket_acl).and_raise(MyError.new("some-error-message"))

          expect { subject }.to raise_error(RiakCsBroker::ServiceInstances::ClientError, "MyError: some-error-message")
        end
      end
    end
  end
end
