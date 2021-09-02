require 'spec_helper'

describe 'Version', type: :request do
  before { create_list(:country, 2) }

  describe '/api' do
    it 'returns 404' do
      get '/api/countries'
      expect(response).to have_http_status 404
    end
  end

  describe '/api/v1' do
    it 'be successful' do
      get '/api/v1/countries'
      expect(response).to have_http_status 200
    end
  end
end
