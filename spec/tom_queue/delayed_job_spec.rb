require 'tom_queue/helper'

describe TomQueue, "once hooked" do

  let(:job) { Delayed::Job.create! }
  let(:new_job) { Delayed::Job.new }

  before do
    TomQueue.logger ||= Logger.new("/dev/null")
    TomQueue.default_prefix = "default-prefix"
    TomQueue.hook_delayed_job!
    Delayed::Job.class_variable_set(:@@tomqueue_manager, nil)
  end

  it "should set the Delayed::Worker sleep delay to 0" do
    # This makes sure the Delayed::Worker loop spins around on
    # an empty queue to block on TomQueue::QueueManager#pop, so
    # the job will start as soon as we receive a push from RMQ
    Delayed::Worker.sleep_delay.should == 0
  end

  describe "TomQueue::DelayedJobHook::Job" do
    it "should use the TomQueue job as the Delayed::Job" do
      Delayed::Job.should == TomQueue::DelayedJobHook::Job
    end

    it "should be a subclass of ::Delayed::Backend::ActiveRecord::Job" do
      TomQueue::DelayedJobHook::Job.superclass.should == ::Delayed::Backend::ActiveRecord::Job
    end
  end

  describe "Delayed::Job.tomqueue_manager" do
    it "should return a TomQueue::QueueManager instance" do
      Delayed::Job.tomqueue_manager.should be_a(TomQueue::QueueManager)
    end

    it "should have used the default prefix configured" do
      Delayed::Job.tomqueue_manager.prefix.should == "default-prefix"
    end

    it "should return the same object on subsequent calls" do
      Delayed::Job.tomqueue_manager.should == Delayed::Job.tomqueue_manager
    end

    it "should be reset by rspec (1)" do
      TomQueue.default_prefix = "foo"
      Delayed::Job.tomqueue_manager.prefix.should == "foo"
    end

    it "should be reset by rspec (2)" do
      TomQueue.default_prefix = "bar"
      Delayed::Job.tomqueue_manager.prefix.should == "bar"
    end
  end

  describe "Delayed::Job#tomqueue_digest" do

    it "should return a different value when the object is saved" do
      first_digest = job.tomqueue_digest
      job.update_attributes(:run_at => Time.now + 10.seconds)
      job.tomqueue_digest.should_not == first_digest
    end

    it "should return the same value, regardless of the time zone (regression)" do
      ActiveRecord::Base.time_zone_aware_attributes = true
      old_zone, Time.zone = Time.zone, "Hawaii"

      job = Delayed::Job.create!
      first_digest = job.tomqueue_digest

      Time.zone = "Auckland"

      job = Delayed::Job.find(job.id)
      job.tomqueue_digest.should == first_digest

      Time.zone = old_zone
    end
  end

  describe "Delayed::Job#tomqueue_payload" do
 
    let(:payload) { JSON.load(job.tomqueue_payload)}
 
    it "should return a hash" do
      payload.should be_a(Hash)
    end

    it "should contain the job id" do
      payload['delayed_job_id'].should == job.id
    end

    it "should contain the current updated_at timestamp (with second-level precision)" do
      payload['delayed_job_updated_at'].should == job.updated_at.iso8601(0)
    end

    it "should contain the digest after saving" do
      payload['delayed_job_digest'].should == job.tomqueue_digest
    end
  end

  describe "Delayed::Job#tomqueue_publish" do

    it "should return nil" do
      job.tomqueue_publish.should be_nil
    end

    it "should raise an exception if it is called on an unsaved job" do
      TomQueue.exception_reporter = double("SilentExceptionReporter", :notify => nil)
      lambda {
        Delayed::Job.new.tomqueue_publish
      }.should raise_exception(ArgumentError, /cannot publish an unsaved Delayed::Job/)
    end

    describe "when it is called on a persisted job" do

      before do
        job # create the job first so we don't trigger the expectation twice

        @called = false
        Delayed::Job.tomqueue_manager.should_receive(:publish) do |payload, opts|
          @called = true
          @payload = payload
          @opts = opts
        end
      end

      it "should call publish on the queue manager" do
        job.tomqueue_publish
        @called.should be_true
      end

      describe "job priority" do
        before do
          TomQueue::DelayedJobHook::Job.tomqueue_priority_map[-10] = TomQueue::BULK_PRIORITY
          TomQueue::DelayedJobHook::Job.tomqueue_priority_map[10]  = TomQueue::HIGH_PRIORITY
        end

        it "should map the priority of the job to the TomQueue priority" do
          new_job.priority = -10
          new_job.save
          @opts[:priority].should == TomQueue::BULK_PRIORITY
        end

        describe "if an unknown priority value is used" do
          before do
            new_job.priority = 99
          end

          it "should default the priority to TomQueue::NORMAL_PRIORITY" do
            new_job.save
            @opts[:priority].should == TomQueue::NORMAL_PRIORITY
          end

          it "should log a warning" do
            TomQueue.logger.should_receive(:warn)
            new_job.save
          end
        end
      end

      describe "run_at value" do

        it "should use the job's :run_at value by default" do
          job.tomqueue_publish
          @opts[:run_at].should == job.run_at
        end

        it "should use the run_at value provided if provided by the caller" do
          the_time = Time.now + 10.seconds
          job.tomqueue_publish(the_time)
          @opts[:run_at].should == the_time
        end

      end

      describe "the payload" do

        before { job.stub(:tomqueue_payload => "PAYLOAD") }

        it "should be the return value from #tomqueue_payload" do
          job.tomqueue_publish
          @payload.should == "PAYLOAD"
        end
      end
    end

    describe "if an exception is raised during the publish" do
      let(:exception) { RuntimeError.new("Bugger. Dropped the ball, sorry.") }

      before do
        TomQueue.exception_reporter = double("SilentExceptionReporter", :notify => nil)
        Delayed::Job.tomqueue_manager.should_receive(:publish).and_raise(exception)
      end

      it "should not be raised out to the caller" do
        lambda { new_job.save }.should_not raise_exception
      end

      it "should notify the exception reporter" do
        TomQueue.exception_reporter.should_receive(:notify).with(exception)
        new_job.save
      end

      it "should do nothing if the exception reporter is nil" do
        TomQueue.exception_reporter = nil
        lambda { new_job.save }.should_not raise_exception
      end
      
      it "should log an error message to the log" do
        TomQueue.logger.should_receive(:error)
        new_job.save
      end
    end
  end

  describe "publish callbacks in Job lifecycle" do

    xit "should allow Mock::ExpectationFailed exceptions to escape the callback" do
      Delayed::Job.tomqueue_manager.should_receive(:publish).with("spurious arguments").once
      lambda {
        job.update_attributes(:run_at => Time.now + 5.seconds)
      }.should raise_exception(RSpec::Mocks::MockExpectationError)
    end    

    it "should not publish a message if the job has a non-nil failed_at" do
      # This is a ball-ache. after_commit swallows all exceptions, including the Mock::ExpectationFailed 
      # ones that would otherwise fail this spec if should_not_receive were used.
      job.stub(:tomqueue_publish) { @called = true }
      job.update_attributes(:failed_at => Time.now)
      @called.should be_nil
    end

    it "should be called after create when there is no explicit transaction" do
      new_job.should_receive(:tomqueue_publish).with(no_args)
      new_job.save!
    end

    it "should be called after update when there is no explicit transaction" do
      job.should_receive(:tomqueue_publish).with(no_args)
      job.run_at = Time.now + 10.seconds
      job.save!
    end

    it "should be called after commit, when a record is saved" do
      new_job.stub(:tomqueue_publish) { @called = true }

      Delayed::Job.transaction do
        new_job.save!
        @called.should be_nil
        new_job.unstub(:tomqueue_publish)
        new_job.should_receive(:tomqueue_publish).with(no_args)
      end
    end

    it "should be called after commit, when a record is updated" do
      job.stub(:tomqueue_publish) { @called = true }

      Delayed::Job.transaction do
        job.run_at = Time.now + 10.seconds
        job.save!
        @called.should be_nil

        job.unstub(:tomqueue_publish)
        job.should_receive(:tomqueue_publish).with(no_args)
      end
    end

    it "should not be called when a record is destroyed" do
      job.stub(:tomqueue_publish) { @called = true } # See first use of this for explaination
      job.destroy
      @called.should be_nil
    end

    it "should not be called by a destroy in a transaction" do
      job.stub(:tomqueue_publish) { @called = true } # See first use of this for explaination
      Delayed::Job.transaction { job.destroy }
      @called.should be_nil
    end

    it "should not be called if the update transaction is rolled back" do
      job.stub(:tomqueue_publish) { @called = true }

      Delayed::Job.transaction do
        job.run_at = Time.now + 10.seconds
        job.save!
        raise ActiveRecord::Rollback
      end
      @called.should be_nil
    end

    it "should not be called if the create transaction is rolled back" do
      new_job.stub(:tomqueue_publish) { @called = true }

      Delayed::Job.transaction do
        new_job.save!
        raise ActiveRecord::Rollback
      end
      @called.should be_nil
    end
  end

  describe "Delayed::Job.tomqueue_republish method" do

    it "should exist" do
      Delayed::Job.respond_to?(:tomqueue_republish).should be_true
    end

    it "should return nil" do
      Delayed::Job.tomqueue_republish.should be_nil
    end

    xit "should call #tomqueue_publish on all DB records" do

    end
  end

  describe "Delayed::Job.acquire_locked_job" do
    let(:time) { Time.now }
    before { Delayed::Job.stub(:db_time_now => time) }
    
    let(:job) { Delayed::Job.create! }
    let(:worker) { Delayed::Worker.new }

    # make sure the job exists!
    before { job }

    subject { Delayed::Job.acquire_locked_job(job.id, worker, &@block) }

    describe "when the job doesn't exist" do
      before { job.destroy }

      it "should return nil" do
        subject.should be_nil
      end

      it "should not yield if a block is provided" do
        @block = lambda { |value| @called = true}
        subject
        @called.should be_nil
      end
    end

    describe "when the job exists" do

      it "should hold an explicit DB lock whilst performing the lock" do
        pending("Only possible when using mysql2 adapter (ADAPTER=mysql environment)") unless ActiveRecord::Base.connection.class == ActiveRecord::ConnectionAdapters::Mysql2Adapter

        # Ok, fudge a second parallel connection to MySQL
        second_connection = ActiveRecord::Base.connection.dup
        second_connection.reconnect!
        ActiveRecord::Base.connection.reset!

        # Assert we have separate connections
        second_connection.select("SELECT connection_id() as id;").first["id"].should_not ==
          ActiveRecord::Base.connection.select("SELECT connection_id() as id;").first["id"]

        # This is called in a thread when the transaction is open to query the job, store the response
        # and the time when the response comes back
        parallel_query = lambda do |job_id|
          begin
            # Simulate another worker performing a SELECT ... FOR UPDATE request
            @query_result = second_connection.select("SELECT * FROM delayed_jobs WHERE id=#{job_id} LIMIT 1 FOR UPDATE").first
            @query_returned_at = Time.now.to_f
          rescue
            puts "Failed #{$!.inspect}"
          end
        end

        # When we have the transaction open, we emit a query on a parallel thread and check the timing
        @block = lambda do |job|
          @thread = Thread.new(job.id, &parallel_query)
          sleep 0.25
          @leaving_transaction_at = Time.now.to_f
          true
        end
        
        # Kick it all off !
        subject
          
        @thread.join

        # now make sure the parallel thread blocked until the transaction returned
        @query_returned_at.should > @leaving_transaction_at

        # make sure the returned record showed the lock
        @query_result["locked_at"].should_not be_nil
        @query_result["locked_by"].should_not be_nil
      end

      describe "when the job is not locked" do
        
        it "should acquire the lock fields on the job" do
          subject
          job.reload
          job.locked_at.should == time
          job.locked_by.should == worker.name
        end

        it "should return the job object" do
          subject.should be_a(Delayed::Job)
          subject.id.should == job.id
        end

        it "should yield the job to the block if present" do
          @block = lambda { |value| @called = value}
          subject
          @called.should be_a(Delayed::Job)
          @called.id.should == job.id
        end

        it "should not have locked the job when the block is called" do
          @block = lambda { |job| @called = [job.id, job.locked_at, job.locked_by]; true }
          subject
          @called.should == [job.id, nil, nil]
        end

        describe "if the supplied block returns true" do
          before { @block = lambda { |_| true } }

          it "should lock the job" do
            subject
            job.reload
            job.locked_at.should == time
            job.locked_by.should == worker.name
          end

          it "should return the job" do
            subject.should be_a(Delayed::Job)
            subject.id.should == job.id
          end
        end

        describe "if the supplied block returns false" do
          before { @block = lambda { |_| false } }

          it "should not lock the job" do
            subject
            job.reload
            job.locked_at.should be_nil
            job.locked_by.should be_nil
          end

          it "should return nil" do
            subject.should be_nil
          end
        end
      end

      describe "when the job is locked with a valid lock" do
        before do
          @old_locked_by = job.locked_by = "some worker"
          @old_locked_at = job.locked_at = Time.now
          job.save!
        end

        it "should not yield to a block if provided" do
          @called = false
          @block = lambda { |_| @called = true}
          subject
          @called.should be_false
        end

        it "should return false" do
          subject.should be_false
        end

        it "should not change the lock" do
          subject
          job.reload
          job.locked_by.should == @old_locked_by
          job.locked_at.should == @old_locked_at
        end

      end

      describe "when the job is locked with a stale lock" do
        before do
          @old_locked_by = job.locked_by = "some worker"
          @old_locked_at = job.locked_at = (Time.now - Delayed::Worker.max_run_time - 1)
          job.save!
        end

        it "should return the job" do
          subject.should be_a(Delayed::Job)
          subject.id.should == job.id
        end

        it "should update the lock" do
          subject
          job.reload
          job.locked_at.should_not == @old_locked_at
          job.locked_by.should_not == @old_locked_by
        end

        # This is tricky - if we have a stale lock, the job object
        # will have been updated by the first worker, so the digest will
        # now be invalid (since updated_at will have changed)
        #
        # So, we don't yield, we just presume we're carrying on from where
        # a previous worker left off and don't try and validate the job any
        # further.
        it "should not yield the block if supplied" do
          @called = false
          @block = lambda { |_| @called = true}
          subject
          @called.should be_false
        end
      end

    end

  end

  describe "Delayed::Job#reserve - return the next job" do
    let(:job)     { Delayed::Job.create! }
    let(:worker)  { double("Worker", :name => "Worker-Name-#{Time.now.to_f}") }
    let(:payload) { job.tomqueue_payload }
    let(:work)    { double("Work", :payload => payload, :ack! => nil) }

    before do
      Delayed::Job.tomqueue_manager.stub(:pop => work)
    end

    it "should call pop on the queue manager" do
      Delayed::Job.tomqueue_manager.should_receive(:pop)
      Delayed::Job.reserve(worker)
    end

    describe "signal handling" do
      it "should allow signal handlers during the pop" do
        Delayed::Worker.raise_signal_exceptions = false
        Delayed::Job.tomqueue_manager.should_receive(:pop) do
          Delayed::Worker.raise_signal_exceptions.should be_true
          work
        end
        Delayed::Job.reserve(worker)
      end

      it "should reset the signal handler var after the pop" do
        Delayed::Worker.raise_signal_exceptions = false
        Delayed::Job.reserve(worker)
        Delayed::Worker.raise_signal_exceptions.should == false
        Delayed::Worker.raise_signal_exceptions = true
        Delayed::Job.reserve(worker)
        Delayed::Worker.raise_signal_exceptions.should == true
      end

      it "should allow exceptions to escape the function" do
        Delayed::Job.tomqueue_manager.should_receive(:pop) do
          raise SignalException, "INT"
        end
        lambda {
          Delayed::Job.reserve(worker)
        }.should raise_exception(SignalException)
      end
    end

    describe "Job#invoke_job" do
      let(:payload) { double("DelayedJobPayload", :perform => nil)}
      let(:job) { Delayed::Job.create!(:payload_object=>payload) }

      it "should perform the job" do
        payload.should_receive(:perform)
        job.invoke_job
      end

      it "should not have a problem if tomqueue_work is nil" do
        job.tomqueue_work = nil
        job.invoke_job
      end

      describe "if there is a tomqueue work object set on the object" do
        let(:work_object) { double("WorkObject", :ack! => nil)}
        before { job.tomqueue_work = work_object}

        it "should call ack! on the work object after the job has been invoked" do
          payload.should_receive(:perform).ordered
          work_object.should_receive(:ack!).ordered
          job.invoke_job
        end

        it "should call ack! on the work object if an exception is raised" do
          payload.should_receive(:perform).ordered.and_raise(RuntimeError, "OMG!!!11")
          work_object.should_receive(:ack!).ordered
          lambda {
            job.invoke_job
          }.should raise_exception(RuntimeError, "OMG!!!11")
        end
      end
    end

    describe "if a nil message is popped" do
      before { Delayed::Job.tomqueue_manager.stub(:pop=>nil) }

      it "should return nil" do
        Delayed::Job.reserve(worker).should be_nil
      end
      it "should sleep for a second to avoid potentially tight loops" do
        start_time = Time.now
        Delayed::Job.reserve(worker).should be_nil
        (Time.now - start_time).should > 1.0
      end
    end

    describe "when a TomQueue::Work object is returned" do

      let(:the_time) { Time.now }
      before { Delayed::Job.stub(:db_time_now => the_time) }

      describe "for a job that is ready to run and not locked" do
        it "should return the job object" do
          Delayed::Job.reserve(worker).should == job
        end

        it "should not ack the work object" do
          work.should_not_receive(:ack!)
          Delayed::Job.reserve(worker)
        end

        it "should assign the work object to the delayed job" do
          Delayed::Job.reserve(worker).tomqueue_work.should == work
        end

        it "should lock the job" do
          Delayed::Job.reserve(worker)

          job.reload
          job.locked_at.to_i.should == the_time.to_i
          job.locked_by.should == worker.name
        end

        it "should not trigger the tomqueue_publish callback when locking the job" do
          @publish_called = false
          Delayed::Job.tomqueue_manager.stub(:publish) { @publish_called = true }
          Delayed::Job.reserve(worker)
          @publish_called.should be_false
        end

        it "should leave the job object such that future .save! trigger the tomqueue_publish" do
          job = Delayed::Job.reserve(worker)

          @called = false
          Delayed::Job.tomqueue_manager.stub(:publish) { @called = true }
          job.touch(:updated_at)
          job.save!
          @called.should be_true
        end

        describe "if there is an error during reserve" do
          before do
            Delayed::Job.should_receive(:db_time_now).and_raise(RuntimeError, "YAK NOT FOUND")
          end

          it "should not ack the job" do
            work.should_not_receive(:ack!)            
            Delayed::Job.reserve(worker) rescue nil
          end

          it "should let the exception fall out to the caller" do
            lambda {
              Delayed::Job.reserve(worker)
            }.should raise_exception(RuntimeError, "YAK NOT FOUND")
          end
        end
      end

      describe "if the job has been updated since the message" do
        before do
          job.update_attributes!(:run_at => Time.now + 5)
        end
        it "should ack the message" do
          work.should_receive(:ack!)
          Delayed::Job.reserve(worker)
        end
        it "should return nil" do
          Delayed::Job.reserve(worker).should be_nil
        end
        it "should not have locked the job" do
          Delayed::Job.reserve(worker)
          job.reload
          job.locked_by.should be_nil
        end
      end

      describe "if the job is locked, less than max_run_time ago" do
        # This will potentially happen if a worker crashes mid-job and 
        # the broker re-delivers the original message.
        #
        # It's worth pointing out that since the original worker will have
        # locked the job, the digest will no longer match!
        #

        before do
          # First worker pops the job
          Delayed::Job.reserve(worker).should == job
          job.reload

          # Fake out the message an updated message
          work.stub(:payload => job.tomqueue_payload)

          # Fake out "the future", but not as far as max_run_time...
          Delayed::Job.stub(:db_time_now => job.locked_at + 10)
        end

        it "should return nil" do
          Delayed::Job.reserve(worker).should be_nil
        end

        it "should ack the message" do
          work.should_receive(:ack!)
          Delayed::Job.reserve(worker)
        end

        it "should publish a notification to arrive at locked_at + max_run_time" do
          Delayed::Job.tomqueue_manager.should_receive(:publish).with(anything(),
             hash_including(:run_at => job.locked_at + Delayed::Worker.max_run_time))
          Delayed::Job.reserve(worker)
        end
      end

      describe "if the job is locked, more than max_run_time ago" do
        # Looks like, according to DJ, this job has crashed. Boo Hoo.
        # 
        # The worker should carry on as if the job weren't locked.

        before do
          # First worker pops the job
          Delayed::Job.reserve(worker).should == job
          job.reload

          # Fake out the message an updated message
          work.stub(:payload => job.tomqueue_payload)

          # Fake out "the future"...
          Delayed::Job.stub(:db_time_now => job.locked_at + Delayed::Worker.max_run_time)
        end

        it "should return the job" do
          Delayed::Job.reserve(worker).should == job
        end

        it "should re-lock the job" do
          worker.stub(:name => "new_name_#{Time.now.to_f}")
          Delayed::Job.reserve(worker)
          job.reload
          job.locked_at.should == Delayed::Job.db_time_now
          job.locked_by.should == worker.name
        end

        it "should not ack the message" do
          work.should_not_receive(:ack!)
          Delayed::Job.reserve(worker)
        end
      end

      describe "if the job doesn't exist" do
        before do
          job.destroy
        end

        it "should ack the message" do
          work.should_receive(:ack!)
          Delayed::Job.reserve(worker)
        end

        it "should return nil" do
          Delayed::Job.reserve(worker).should be_nil
        end
      end

      # describe "if the job has a run_at in the future" do
      #   # Hmm, this is a tricky one. Again this message should have been delivered
      #   # on time and any updates to the job should have invalidated the updated_at
      #   # field.
      #   #
      #   # So I think in this case we'll just presume the message is OK and chalk the
      #   # problem down to clock sync issues between the deferred worker and the 
      #   # running worker
      #   it "shoudl lock teh job" do

      #     job.locked_at
      #   end
      #   it "should return the job"
      #   it "shoudl ack the message"

      # end
      
      describe "if the job's failed_at value is non-nil" do
        before do
          job.failed_at = Time.now
          job.save
        end
        it "should return nil" do
          Delayed::Job.reserve(worker).should be_nil
        end
        it "should not lock the job" do
          Delayed::Job.reserve(worker)
          job.reload
          job.locked_by.should be_nil
        end
        it "should ack the message" do
          work.should_receive(:ack!)
          Delayed::Job.reserve(worker)
        end
      end

      describe "if someone tries to update the object after a worker has locked it" do
        # We need to be careful if someone on the console tweaks a job that has started
        # so we'll need to wrap updates with some implicit locking and alerting.

      end

    end

  end


end