FROM node:12-slim

USER node

WORKDIR /home/node
COPY package*.json ./

RUN npm install --only=production
COPY . .

# Run service.
CMD [ "npm", "start" ]
