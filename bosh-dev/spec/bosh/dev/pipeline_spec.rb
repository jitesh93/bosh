require 'spec_helper'
require 'fileutils'
require 'fakefs/spec_helpers'

require 'bosh/dev/pipeline'
require 'bosh/dev/stemcell'
require 'bosh/dev/build'
require 'bosh/dev/infrastructure'

module Bosh::Dev
  describe Pipeline do
    include FakeFS::SpecHelpers

    let(:fog_storage) { Fog::Storage.new(provider: 'AWS', aws_access_key_id: 'fake access key', aws_secret_access_key: 'fake secret key') }
    let(:bucket_files) { fog_storage.directories.get('bosh-ci-pipeline').files }
    let(:bucket_name) { 'bosh-ci-pipeline' }
    let(:logger) { instance_double('Logger').as_null_object }
    let(:build_id) { '456' }
    let(:download_directory) { '/FAKE/CUSTOM/WORK/DIRECTORY' }
    let(:distro) { 'ubuntu_lucid' }

    subject(:pipeline) { Pipeline.new(fog_storage: fog_storage, logger: logger, build_id: build_id) }

    before do
      Fog.mock!
      Fog::Mock.reset
      fog_storage.directories.create(key: bucket_name) if bucket_name
      ENV.stub(to_hash: {
          'AWS_ACCESS_KEY_ID_FOR_STEMCELLS_JENKINS_ACCOUNT' => 'fake access key',
          'AWS_SECRET_ACCESS_KEY_FOR_STEMCELLS_JENKINS_ACCOUNT' => 'fake secret key',
      })
    end

    its(:s3_url) { should eq('s3://bosh-ci-pipeline/456/') }
    its(:gems_dir_url) { should eq('https://s3.amazonaws.com/bosh-ci-pipeline/456/gems/') }

    describe '#initialize' do
      context 'when initialized without any dependencies' do
        subject(:pipeline) { Pipeline.new }

        before do
          Build.stub(candidate: instance_double('Build', number: '102948923'))
        end

        it 'defaults to the current candidate build_id' do
          expect(pipeline.s3_url).to eq 's3://bosh-ci-pipeline/102948923/'
        end

        it 'uses a default logger to stdout' do
          Logger.should_receive(:new).with($stdout)
          pipeline
        end

        it "defaults to the environment's s3 aws credentials" do
          expect(pipeline.fog_storage).not_to be_nil
          expect(pipeline.fog_storage.instance_variable_get(:@aws_access_key_id)).to eq('fake access key')
          expect(pipeline.fog_storage.instance_variable_get(:@aws_secret_access_key)).to eq('fake secret key')
        end
      end
    end

    describe '#create' do
      let(:bucket) { fog_storage.directories.get(bucket_name) }

      it 'creates the specified file on the pipeline bucket' do
        pipeline.create(key: 'dest_dir/foo/bar/baz.txt', body: 'contents of baz', public: true)

        expect(bucket.files.map(&:key)).to include '456/dest_dir/foo/bar/baz.txt'
        expect(bucket.files.get('456/dest_dir/foo/bar/baz.txt').body).to eq('contents of baz')
        expect(bucket.files.get('456/dest_dir/foo/bar/baz.txt').public_url).not_to be_nil
      end

      it 'publicizes the bucket only when asked to' do
        logger.should_receive(:info).with('uploaded to s3://bosh-ci-pipeline/456/dest_dir/foo/bar/baz.txt')
        pipeline.create(key: 'dest_dir/foo/bar/baz.txt', body: 'contents of baz', public: false)

        expect(bucket.files.map(&:key)).to include '456/dest_dir/foo/bar/baz.txt'
        expect(bucket.files.get('456/dest_dir/foo/bar/baz.txt').public_url).to be_nil
      end

      context 'when the bucket does not exist' do
        let(:bucket_name) { false }

        it 'raises an error' do
          expect { pipeline.create({}) }.to raise_error("bucket 'bosh-ci-pipeline' not found")
        end
      end
    end

    describe '#s3_upload' do
      before do
        File.open('foobar-path', 'w') { |f| f.write('test data') }
      end

      it 'uploads the file to the specific path on the pipeline bucket' do
        logger.should_receive(:info).with('uploaded to s3://bosh-ci-pipeline/456/foo-bar.tgz')

        pipeline.s3_upload('foobar-path', 'foo-bar.tgz')
        expect(bucket_files.map(&:key)).to include '456/foo-bar.tgz'
        expect(bucket_files.get('456/foo-bar.tgz').body).to eq 'test data'
      end
    end

    describe '#publish_stemcell' do
      let(:stemcell) { double(Stemcell, light?: false, path: '/tmp/bosh-stemcell-aws.tgz', infrastructure: 'aws', name: 'bosh-stemcell') }

      before do
        FileUtils.mkdir('/tmp')
        File.open(stemcell.path, 'w') { |f| f.write(stemcell_contents) }
        logger.stub(:info)
      end

      describe 'when publishing a full stemcell' do
        let(:stemcell_contents) { 'contents of the stemcells' }
        let(:stemcell) { instance_double('Stemcell', light?: false, path: '/tmp/bosh-stemcell-aws.tgz', infrastructure: 'aws', name: 'bosh-stemcell') }

        it 'publishes a stemcell to an S3 bucket' do
          logger.should_receive(:info).with('uploaded to s3://bosh-ci-pipeline/456/bosh-stemcell/aws/bosh-stemcell-aws.tgz')

          pipeline.publish_stemcell(stemcell)

          expect(bucket_files.map(&:key)).to include '456/bosh-stemcell/aws/bosh-stemcell-aws.tgz'
          expect(bucket_files.get('456/bosh-stemcell/aws/bosh-stemcell-aws.tgz').body).to eq 'contents of the stemcells'
        end

        it 'updates the latest stemcell in the S3 bucket' do
          logger.should_receive(:info).with("uploaded to s3://bosh-ci-pipeline/456/bosh-stemcell/aws/stemcell-latest-aws-image-xen-amd64-#{distro}.tgz")

          pipeline.publish_stemcell(stemcell)

          filename = "456/bosh-stemcell/aws/stemcell-latest-aws-image-xen-amd64-#{distro}.tgz"

          expect(bucket_files.map(&:key)).to include filename
          expect(bucket_files.get(filename).body).to eq 'contents of the stemcells'
        end
      end

      describe 'when publishing a light stemcell' do
        let(:stemcell_contents) { 'this file is a light stemcell' }
        let(:stemcell) { instance_double('Stemcell', light?: true, path: '/tmp/light-bosh-stemcell-aws.tgz', infrastructure: 'aws', name: 'bosh-stemcell') }

        it 'publishes a light stemcell to S3 bucket' do
          pipeline.publish_stemcell(stemcell)

          expect(bucket_files.map(&:key)).to include '456/bosh-stemcell/aws/light-bosh-stemcell-aws.tgz'
          expect(bucket_files.get('456/bosh-stemcell/aws/light-bosh-stemcell-aws.tgz').body).to eq 'this file is a light stemcell'
        end

        it 'updates the latest light stemcell in the s3 bucket' do
          pipeline.publish_stemcell(stemcell)

          filename = "456/bosh-stemcell/aws/stemcell-latest-aws-ami-xen-amd64-#{distro}.tgz"

          expect(bucket_files.map(&:key)).to include filename
          expect(bucket_files.get(filename).body).to eq 'this file is a light stemcell'
        end
      end
    end

    describe '#download_stemcell' do
      before do
        bucket_files.create(key: "456/stemcell/aws/stemcell-456-aws-image-xen-amd64-#{distro}.tgz", body: 'this is a thinga-ma-jiggy')
        bucket_files.create(key: "456/stemcell/aws/stemcell-456-aws-ami-xen-amd64-#{distro}.tgz", body: 'this a completely different thingy')
      end

      it 'downloads the specified stemcell version from the pipeline bucket' do
        logger.should_receive(:info).with(
            "downloaded 's3://bosh-ci-pipeline/456/stemcell/aws/stemcell-456-aws-image-xen-amd64-#{distro}.tgz' -> 'stemcell-456-aws-image-xen-amd64-#{distro}.tgz'")

        pipeline.download_stemcell('456', infrastructure: Infrastructure.for('aws'), name: 'stemcell', light: false)
        expect(File.read("stemcell-456-aws-image-xen-amd64-#{distro}.tgz")).to eq 'this is a thinga-ma-jiggy'
      end

      context 'when remote file does not exist' do
        it 'raises' do
          expect {
            pipeline.download_stemcell('888', infrastructure: Infrastructure.for('vsphere'), name: 'fooey', light: false)
          }.to raise_error("remote stemcell 'fooey-888-vsphere-image-esxi-amd64-#{distro}.tgz' not found")
        end

      end

      it 'downloads the specified light stemcell version from the pipeline bucket' do
        logger.should_receive(:info).with(
            "downloaded 's3://bosh-ci-pipeline/456/stemcell/aws/stemcell-456-aws-ami-xen-amd64-#{distro}.tgz' -> 'stemcell-456-aws-ami-xen-amd64-#{distro}.tgz'")

        pipeline.download_stemcell('456', infrastructure: Infrastructure.for('aws'), name: 'stemcell', light: true)
        expect(File.read("stemcell-456-aws-ami-xen-amd64-#{distro}.tgz")).to eq 'this a completely different thingy'
      end
    end

    describe '#bosh_stemcell_path' do
      let(:infrastructure) { Bosh::Dev::Infrastructure::Aws.new }

      it 'works' do
        expect(subject.bosh_stemcell_path(infrastructure, download_directory)).to eq(File.join(download_directory, "stemcell-456-aws-ami-xen-amd64-#{distro}.tgz"))
      end
    end

    describe '#micro_bosh_stemcell_path' do
      let(:infrastructure) { Bosh::Dev::Infrastructure::Vsphere.new }

      it 'works' do
        expect(subject.micro_bosh_stemcell_path(
                   infrastructure, download_directory)).to eq(File.join(download_directory, "micro_stemcell-456-vsphere-image-esxi-amd64-#{distro}.tgz"))
      end
    end

    describe '#fetch_stemcells' do
      let(:infrastructure) { Bosh::Dev::Infrastructure::Aws.new }

      before do
        FileUtils.mkdir_p(download_directory)
      end

      context 'when micro and bosh stemcells exist for infrastructure' do
        before do
          bucket_files.create(key: "456/stemcell/aws/stemcell-456-aws-ami-xen-amd64-#{distro}.tgz", body: 'this is the light-bosh-stemcell')
          bucket_files.create(key: "456/micro_stemcell/aws/micro_stemcell-456-aws-ami-xen-amd64-#{distro}.tgz", body: 'this is the micro-bosh-stemcell')
        end

        it 'downloads the specified stemcell version from the pipeline bucket' do
          pipeline.fetch_stemcells(infrastructure, download_directory)

          expect(File.read(File.join(download_directory, "stemcell-456-aws-ami-xen-amd64-#{distro}.tgz"))).to eq('this is the light-bosh-stemcell')
          expect(File.read(File.join(download_directory, "micro_stemcell-456-aws-ami-xen-amd64-#{distro}.tgz"))).to eq('this is the micro-bosh-stemcell')
        end
      end

      context 'when remote file does not exist' do
        it 'raises' do
          expect {

            pipeline.fetch_stemcells(infrastructure, download_directory)
          }.to raise_error("remote stemcell 'micro_stemcell-456-aws-ami-xen-amd64-#{distro}.tgz' not found")
        end
      end
    end

    describe '#stemcell_filename' do

      context 'when all parts are provided' do
        it 'builds the stemcell filename' do
          options = {
              version: 123,
              infrastructure: 'aws',
              format: 'image',
              hypervisor: 'xen',
              arch: 'amd64',
              distro: distro,
          }

          expect(pipeline.stemcell_filename(options)).to eq "stemcell-123-aws-image-xen-amd64-#{distro}.tgz"
        end
      end

      context 'when one of the parts is missing' do
        it 'foo' do
          expect {
            pipeline.stemcell_filename(
                infrastructure: 'aws',
                format: 'image',
                hypervisor: 'xen',
                arch: 'amd64',
                distro: distro)
          }.to raise_error(KeyError, 'key not found: :version')
        end
      end

    end

    describe '#cleanup_stemcells' do
      it 'removes stemcells created during the build' do
        FileUtils.mkdir_p(download_directory)
        FileUtils.touch(File.join(download_directory, 'foo-bosh-stemcell-bar.tgz'))
        FileUtils.touch(File.join(download_directory, 'foo-micro-bosh-stemcell-bar.tgz'))

        expect {
          subject.cleanup_stemcells(download_directory)
        }.to change { Dir.glob(File.join(download_directory, '*')) }.to([])
      end
    end
  end
end
