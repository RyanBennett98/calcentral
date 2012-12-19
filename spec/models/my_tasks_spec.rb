require "spec_helper"

describe "MyTasks" do
  before(:each) do
    @user_id = rand(99999).to_s
    @fake_google_proxy = GoogleProxy.new({fake: true})
    @fake_google_tasks_array = @fake_google_proxy.tasks_list()
    @fake_canvas_proxy = CanvasProxy.new({fake: true})
  end

  it "should load nicely with the pre-recorded fake Google and Canvas proxy feeds using the server's timezone" do
    GoogleProxy.stub(:access_granted?).and_return(true)
    CanvasProxy.stub(:access_granted?).and_return(true)
    GoogleProxy.stub(:new).and_return(@fake_google_proxy)
    CanvasProxy.stub(:new).and_return(@fake_canvas_proxy)
    my_tasks_model = MyTasks.new(@user_id)
    valid_feed = my_tasks_model.get_feed

    # Counts for task types in VCR recording
    overdue_counter = 5
    today_counter = 2
    this_week_counter = 3
    next_week_counter = 6
    unscheduled_counter = 1

    valid_feed["tasks"].each do |task|
      task["title"].blank?.should == false
      task["source_url"].blank?.should == false

      # Whitelist allowed property strings
      whitelist = task["bucket"] =~ (/(Overdue|Due\ Today|Due\ This\ Week|Due\ Next\ Week|Unscheduled)$/i)
      whitelist.should_not be_nil

      case task["bucket"]
        when "Overdue"
          overdue_counter -= 1
        when "Due Today"
          today_counter -= 1
        when "Due This Week"
          this_week_counter -= 1
        when "Due Next Week"
          next_week_counter -= 1
        when "Unscheduled"
          unscheduled_counter -= 1
      end

      if task["emitter"] == "Google Tasks"
        task["link_url"].should == "https://mail.google.com/tasks/canvas?pli=1"
        task["color_class"].should == "google-task"
        if task["due_date"]
          task["due_date"]["date_string"] =~ /\d\d\/\d\d/
          task["due_date"]["epoch"].should >= 1351641600
        end
      end
      if task["emitter"] == CanvasProxy::APP_ID
        task["link_url"].should =~ /https:\/\/ucberkeley.instructure.com\/courses/
        task["link_url"].should == task["source_url"]
        task["color_class"].should == "canvas-class"
        task["due_date"]["date_string"] =~ /\d\d\/\d\d/
        task["due_date"]["epoch"].should >= 1352447940
      end
    end

    overdue_counter.should == 0
    today_counter.should == 0
    this_week_counter.should == 0
    next_week_counter.should == 0
    unscheduled_counter.should == 0
  end

  it "should shift tasks into different buckets with a different timezone " do
    original_time_zone = Time.zone
    begin
      Time.zone = 'Pacific/Tongatapu'
      GoogleProxy.stub(:access_granted?).and_return(true)
      CanvasProxy.stub(:access_granted?).and_return(true)
      GoogleProxy.stub(:new).and_return(@fake_google_proxy)
      CanvasProxy.stub(:new).and_return(@fake_canvas_proxy)
      my_tasks_model = MyTasks.new(@user_id)
      valid_feed = my_tasks_model.get_feed
    ensure
      Time.zone = original_time_zone
    end
  end

  it "should fail general update_tasks param validation, missing required parameters" do
    my_tasks = MyTasks.new @user_id
    expect {
      my_tasks.update_task({"foo" => "badly formatted entry"})
    }.to raise_error { |error|
      error.should be_a(ArgumentError)
      (error.message =~ (/Missing parameter\(s\). Required: \[/)).nil?.should_not == true
    }
  end

  it "should fail general update_tasks param validation, invalid parameter(s)" do
    my_tasks = MyTasks.new @user_id
    expect {
      my_tasks.update_task({"type" => "sometype", "emitter" => "Canvas", "status" => "half-baked" })
    }.to raise_error { |error|
      error.should be_a(ArgumentError)
      error.message.should == "Invalid parameter for: status"
    }
  end

  it "should fail google update_tasks param validation, invalid parameter(s)" do
    my_tasks = MyTasks.new @user_id
    GoogleProxy.stub(:access_granted?).and_return(true)
    expect {
      my_tasks.update_task({"type" => "sometype", "emitter" => "Google Tasks", "status" => "completed" })
    }.to raise_error { |error|
      error.should be_a(ArgumentError)
      error.message.should == "Missing parameter(s). Required: [\"id\"]"
    }
  end

  it "should fail google update_tasks with unauthorized access" do
    my_tasks = MyTasks.new @user_id
    GoogleProxy.stub(:access_granted?).and_return(false)
    response = my_tasks.update_task({"type" => "sometype", "emitter" => "Google Tasks", "status" => "completed", "id" => "foo"})
    response.should == {}
  end

  # Will fail in this case since the task_list_id won't match what's recorded in vcr, nor is a valid "remote" task id.
  it "should fail google update_tasks with a remote proxy error" do
    my_tasks = MyTasks.new @user_id
    GoogleProxy.stub(:access_granted?).and_return(true)
    GoogleProxy.stub(:new).and_return(@fake_google_proxy)
    response = my_tasks.update_task({"type" => "sometype", "emitter" => "Google Tasks", "status" => "completed", "id" => "foo"})
    response.should == {}
  end

  it "should succeed google update_tasks with a properly formatted params" do
    my_tasks = MyTasks.new @user_id
    GoogleProxy.stub(:access_granted?).and_return(true)
    GoogleProxy.stub(:new).and_return(@fake_google_proxy)
    task_list_id, task_id = get_task_list_id_and_task_id
    response = my_tasks.update_task({"type" => "sometype", "emitter" => "Google Tasks", "status" => "completed", "id" => task_id}, task_list_id)
    response["type"].should == "task"
    response["id"].should == task_id
    response["emitter"].should == "Google Tasks"
    response["status"].should == "completed"
  end

  it "should invalidate cache on an update_task" do
    my_tasks = MyTasks.new @user_id
    Rails.cache.should_receive(:fetch).with(MyTasks.cache_key(@user_id), anything())
    my_tasks.get_feed
    GoogleProxy.stub(:access_granted?).and_return(true)
    GoogleProxy.stub(:new).and_return(@fake_google_proxy)
    Rails.cache.should_receive(:delete).with(MyTasks.cache_key(@user_id), anything())
    task_list_id, task_id = get_task_list_id_and_task_id
    response = my_tasks.update_task({"type" => "sometype", "emitter" => "Google Tasks", "status" => "completed", "id" => task_id}, task_list_id)
  end

end

def get_task_list_id_and_task_id
  #slightly roundabout way to get the task_list_ids and task_ids
  proxy = GoogleProxy.new(:fake => true)
  test_task_list = proxy.create_task_list '{"title": "test"}'
  test_task_list.response.status.should == 200
  task_list_id = test_task_list.data["id"]
  new_task = proxy.insert_task(body='{"title": "New Task", "notes": "Please Complete me"}', task_list_id=task_list_id)
  new_task.response.status.should == 200
  task_id = new_task.data["id"]
  [task_list_id, task_id]
end
